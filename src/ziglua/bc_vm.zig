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

// =============================================================================
// Bytecode Execution Engine
// =============================================================================

pub const BcVmState = struct {
    allocator: std.mem.Allocator,
    /// Register file (stack frames overlaid)
    stack: []BcValue,
    stack_top: usize,
    // Current frame base
    stack_base: usize,
    /// Open upvalue chain
    upvalues: std.ArrayList(*Upvalue),

    pub fn init(allocator: std.mem.Allocator, max_stack: usize) !BcVmState {
        const stack = try allocator.alloc(BcValue, max_stack + 64); // extra margin
        @memset(stack, BcValue{ .nil = {} });
        return .{
            .allocator = allocator,
            .stack = stack,
            .stack_top = 0,
            .stack_base = 0,
            .upvalues = std.ArrayList(*Upvalue).initCapacity(allocator, 16) catch @panic("oom"),
        };
    }

    pub fn deinit(self: *BcVmState) void {
        self.allocator.free(self.stack);
        self.upvalues.deinit(self.allocator);
    }

    pub inline fn getReg(self: *BcVmState, idx: u8) BcValue {
        return self.stack[self.stack_base + idx];
    }

    pub inline fn setReg(self: *BcVmState, idx: u8, val: BcValue) void {
        self.stack[self.stack_base + idx] = val;
    }
};

const Upvalue = struct {
    ref: *BcValue,
    next: ?*Upvalue,
    closed: bool,
};

/// Execute a prototype with a fresh VM state
pub fn executePrototype(allocator: std.mem.Allocator, proto: *const Prototype) !BcValue {
    var vm = try BcVmState.init(allocator, proto.max_stack_size);
    defer vm.deinit();
    vm.stack_base = 0;

    const code = proto.code;
    var pc: usize = 0;

    while (pc < code.len) {
        const inst = code[pc];
        const op = getOp(inst);
        const a = getA(inst);

        switch (op) {
            .OP_LOADK => {
                const bx = getBx(inst);
                vm.setReg(a, proto.constants[bx]);
                pc += 1;
            },
            .OP_LOADI => {
                const sbx = getsBx(inst);
                vm.setReg(a, .{ .integer = @intCast(sbx) });
                pc += 1;
            },
            .OP_LOADF => {
                const sbx = getsBx(inst);
                vm.setReg(a, .{ .float = @floatFromInt(sbx) });
                pc += 1;
            },
            .OP_LOADFALSE => {
                vm.setReg(a, .{ .boolean = false });
                pc += 1;
            },
            .OP_LOADTRUE => {
                vm.setReg(a, .{ .boolean = true });
                pc += 1;
            },
            .OP_LOADNIL => {
                const b = getB(inst);
                var i: u8 = a;
                while (i <= a + b) : (i += 1) {
                    vm.setReg(i, .{ .nil = {} });
                }
                pc += 1;
            },
            .OP_MOVE => {
                const b = getB(inst);
                vm.setReg(a, vm.getReg(b));
                pc += 1;
            },
            // Arithmetic
            .OP_ADD => {
                const b = getB(inst);
                const c = getC(inst);
                const vb = vm.getReg(b);
                const vc = vm.getReg(c);
                vm.setReg(a, try arithAdd(vb, vc));
                pc += 1;
            },
            .OP_SUB => {
                const b = getB(inst);
                const c = getC(inst);
                vm.setReg(a, try arithSub(vm.getReg(b), vm.getReg(c)));
                pc += 1;
            },
            .OP_MUL => {
                const b = getB(inst);
                const c = getC(inst);
                vm.setReg(a, try arithMul(vm.getReg(b), vm.getReg(c)));
                pc += 1;
            },
            .OP_DIV => {
                const b = getB(inst);
                const c = getC(inst);
                vm.setReg(a, try arithDiv(vm.getReg(b), vm.getReg(c)));
                pc += 1;
            },
            .OP_MOD => {
                const b = getB(inst);
                const c = getC(inst);
                vm.setReg(a, try arithMod(vm.getReg(b), vm.getReg(c)));
                pc += 1;
            },
            .OP_POW => {
                const b = getB(inst);
                const c = getC(inst);
                vm.setReg(a, try arithPow(vm.getReg(b), vm.getReg(c)));
                pc += 1;
            },
            .OP_IDIV => {
                const b = getB(inst);
                const c = getC(inst);
                vm.setReg(a, try arithIDiv(vm.getReg(b), vm.getReg(c)));
                pc += 1;
            },
            .OP_UNM => {
                const b = getB(inst);
                const vb = vm.getReg(b);
                vm.setReg(a, switch (vb) {
                    .integer => |v| .{ .integer = -v },
                    .float => |v| .{ .float = -v },
                    else => .{ .nil = {} },
                });
                pc += 1;
            },
            .OP_NOT => {
                const b = getB(inst);
                vm.setReg(a, .{ .boolean = !isTruthy(vm.getReg(b)) });
                pc += 1;
            },
            .OP_LEN => {
                const b = getB(inst);
                // Length of string
                const vb = vm.getReg(b);
                vm.setReg(a, switch (vb) {
                    .string => |s| .{ .integer = @intCast(s.len) },
                    else => .{ .integer = 0 },
                });
                pc += 1;
            },
            // Comparison
            .OP_EQ => {
                const b = getB(inst);
                const c = getC(inst);
                const k = getk(inst);
                const eq = valuesEqual(vm.getReg(b), vm.getReg(c));
                if (eq != k) pc += 2 else pc += 1;
            },
            .OP_LT => {
                const b = getB(inst);
                const c = getC(inst);
                const k = getk(inst);
                const lt = try valuesLessThan(vm.getReg(b), vm.getReg(c));
                if (lt != k) pc += 2 else pc += 1;
            },
            .OP_LE => {
                const b = getB(inst);
                const c = getC(inst);
                const k = getk(inst);
                const le = try valuesLessEqual(vm.getReg(b), vm.getReg(c));
                if (le != k) pc += 2 else pc += 1;
            },
            .OP_TEST => {
                const k = getk(inst);
                if (isTruthy(vm.getReg(a)) == k) pc += 2 else pc += 1;
            },
            .OP_TESTSET => {
                const b = getB(inst);
                const k = getk(inst);
                if (isTruthy(vm.getReg(b)) == k) {
                    vm.setReg(a, vm.getReg(b));
                    pc += 2;
                } else {
                    pc += 1;
                }
            },
            // Jump
            .OP_JMP => {
                const sj = getsJ(inst);
                pc = @intCast(@as(i64, @intCast(pc)) + @as(i64, @intCast(sj)));
            },
            // Return
            .OP_RETURN0 => {
                return .{ .nil = {} };
            },
            .OP_RETURN1 => {
                return vm.getReg(a);
            },
            .OP_RETURN => {
                const b = getB(inst);
                _ = b;
                // Return R[A]
                if (a < vm.stack.len - vm.stack_base) {
                    return vm.getReg(a);
                }
                return .{ .nil = {} };
            },
            // For loops
            .OP_FORPREP => {
                const sbx = getsBx(inst);
                const idx = vm.getReg(a);
                const limit = vm.getReg(a + 1);
                const step = vm.getReg(a + 2);
                // Numeric for: prepare
                if (idx == .integer and limit == .integer and step == .integer) {
                    vm.setReg(a, .{ .integer = idx.integer - step.integer });
                } else if (idx == .float) {
                    const s: f64 = if (step == .float) step.float else @floatFromInt(step.integer);
                    vm.setReg(a, .{ .float = idx.float - s });
                }
                pc = @intCast(@as(i64, @intCast(pc)) + @as(i64, @intCast(sbx)));
            },
            .OP_FORLOOP => {
                const sbx = getsBx(inst);
                const idx = vm.getReg(a);
                const limit = vm.getReg(a + 1);
                const step = vm.getReg(a + 2);
                var cont = false;
                if (idx == .integer and limit == .integer and step == .integer) {
                    const new_idx = idx.integer + step.integer;
                    vm.setReg(a, .{ .integer = new_idx });
                    vm.setReg(a + 3, .{ .integer = new_idx });
                    cont = if (step.integer > 0) new_idx <= limit.integer else new_idx >= limit.integer;
                } else if (idx == .float or limit == .float or step == .float) {
                    const fidx: f64 = if (idx == .float) idx.float else @floatFromInt(idx.integer);
                    const flimit: f64 = if (limit == .float) limit.float else @floatFromInt(limit.integer);
                    const fstep: f64 = if (step == .float) step.float else @floatFromInt(step.integer);
                    const new_idx = fidx + fstep;
                    vm.setReg(a, .{ .float = new_idx });
                    vm.setReg(a + 3, .{ .float = new_idx });
                    cont = if (fstep > 0) new_idx <= flimit else new_idx >= flimit;
                }
                if (cont) {
                    pc = @intCast(@as(i64, @intCast(pc)) - @as(i64, @intCast(sbx)));
                } else {
                    pc += 1;
                }
            },
            // Concat
            .OP_CONCAT => {
                const b = getB(inst);
                // R[A] := R[A].. ... ..R[A+b-1]
                var total: usize = 0;
                var j: u8 = 0;
                while (j < b) : (j += 1) {
                    switch (vm.getReg(a + j)) {
                        .string => |s| total += s.len,
                        else => {},
                    }
                }
                const buf = try allocator.alloc(u8, total);
                var off: usize = 0;
                j = 0;
                while (j < b) : (j += 1) {
                    switch (vm.getReg(a + j)) {
                        .string => |s| {
                            @memcpy(buf[off..][0..s.len], s);
                            off += s.len;
                        },
                        else => {},
                    }
                }
                vm.setReg(a, .{ .string = buf });
                pc += 1;
            },
            // NEWTABLE
            .OP_NEWTABLE => {
                vm.setReg(a, .{ .nil = {} }); // placeholder
                pc += 1;
            },
            // CALL — simplified (no actual function calls yet)
            .OP_CALL => {
                // Skip for now — return the value in R[A]
                pc += 1;
            },
            // CLOSURE
            .OP_CLOSURE => {
                const bx = getBx(inst);
                vm.setReg(a, .{ .integer = @intCast(bx) }); // placeholder
                pc += 1;
            },
            // Default: skip unknown instructions
            else => {
                pc += 1;
            },
        }
    }

    return .{ .nil = {} };
}

// =============================================================================
// Arithmetic helpers
// =============================================================================

fn arithAdd(a: BcValue, b: BcValue) !BcValue {
    if (a == .integer and b == .integer) {
        return .{ .integer = a.integer + b.integer };
    }
    const fa: f64 = if (a == .float) a.float else @floatFromInt(a.integer);
    const fb: f64 = if (b == .float) b.float else @floatFromInt(b.integer);
    return .{ .float = fa + fb };
}

fn arithSub(a: BcValue, b: BcValue) !BcValue {
    if (a == .integer and b == .integer) {
        return .{ .integer = a.integer - b.integer };
    }
    const fa: f64 = if (a == .float) a.float else @floatFromInt(a.integer);
    const fb: f64 = if (b == .float) b.float else @floatFromInt(b.integer);
    return .{ .float = fa - fb };
}

fn arithMul(a: BcValue, b: BcValue) !BcValue {
    if (a == .integer and b == .integer) {
        return .{ .integer = a.integer * b.integer };
    }
    const fa: f64 = if (a == .float) a.float else @floatFromInt(a.integer);
    const fb: f64 = if (b == .float) b.float else @floatFromInt(b.integer);
    return .{ .float = fa * fb };
}

fn arithDiv(a: BcValue, b: BcValue) !BcValue {
    const fa: f64 = if (a == .float) a.float else @floatFromInt(a.integer);
    const fb: f64 = if (b == .float) b.float else @floatFromInt(b.integer);
    return .{ .float = fa / fb };
}

fn arithIDiv(a: BcValue, b: BcValue) !BcValue {
    if (a == .integer and b == .integer) {
        if (b.integer == 0) return error.DivisionByZero;
        const result = @divTrunc(a.integer, b.integer);
        return .{ .integer = result };
    }
    const fa: f64 = if (a == .float) a.float else @floatFromInt(a.integer);
    const fb: f64 = if (b == .float) b.float else @floatFromInt(b.integer);
    return .{ .float = @trunc(fa / fb) };
}

fn arithMod(a: BcValue, b: BcValue) !BcValue {
    if (a == .integer and b == .integer) {
        if (b.integer == 0) return error.DivisionByZero;
        return .{ .integer = @mod(a.integer, b.integer) };
    }
    const fa: f64 = if (a == .float) a.float else @floatFromInt(a.integer);
    const fb: f64 = if (b == .float) b.float else @floatFromInt(b.integer);
    return .{ .float = @mod(fa, fb) };
}

fn arithPow(a: BcValue, b: BcValue) !BcValue {
    const fa: f64 = if (a == .float) a.float else @floatFromInt(a.integer);
    const fb: f64 = if (b == .float) b.float else @floatFromInt(b.integer);
    return .{ .float = std.math.pow(f64, fa, fb) };
}

// =============================================================================
// Value helpers
// =============================================================================

fn isTruthy(v: BcValue) bool {
    return switch (v) {
        .nil => false,
        .boolean => |b| b,
        else => true,
    };
}

fn valuesEqual(a: BcValue, b: BcValue) bool {
    const a_tag = std.meta.activeTag(a);
    const b_tag = std.meta.activeTag(b);
    if (a_tag != b_tag) return false;
    return switch (a) {
        .nil => b == .nil,
        .boolean => |v| b == .boolean and b.boolean == v,
        .integer => |v| b == .integer and b.integer == v,
        .float => |v| b == .float and b.float == v,
        .string => |v| b == .string and std.mem.eql(u8, v, b.string),
    };
}

fn valuesLessThan(a: BcValue, b: BcValue) !bool {
    if (a == .integer and b == .integer) return a.integer < b.integer;
    const fa: f64 = if (a == .float) a.float else @floatFromInt(a.integer);
    const fb: f64 = if (b == .float) b.float else @floatFromInt(b.integer);
    return fa < fb;
}

fn valuesLessEqual(a: BcValue, b: BcValue) !bool {
    if (a == .integer and b == .integer) return a.integer <= b.integer;
    const fa: f64 = if (a == .float) a.float else @floatFromInt(a.integer);
    const fb: f64 = if (b == .float) b.float else @floatFromInt(b.integer);
    return fa <= fb;
}

test "bytecode execution: LOADK + RETURN1" {
    const allocator = std.testing.allocator;
    const proto = Prototype{
        .constants = &.{BcValue{ .integer = 42 }},
        .code = &.{
            encodeABx(.OP_LOADK, 0, 0), // R[0] := K[0] = 42
            @intFromEnum(Op.OP_RETURN1) | (@as(Instruction, 0) << POS_A), // return R[0]
        },
        .prototypes = &.{},
        .line_info = &.{},
        .max_stack_size = 2,
        .num_upvalues = 0,
        .num_params = 0,
        .is_vararg = false,
    };
    const result = try executePrototype(allocator, &proto);
    try std.testing.expectEqual(BcValue{ .integer = 42 }, result);
}

test "bytecode execution: LOADI + arithmetic" {
    const allocator = std.testing.allocator;
    const proto = Prototype{
        .constants = &.{},
        .code = &.{
            encodeAsBx(.OP_LOADI, 0, 10), // R[0] := 10
            encodeAsBx(.OP_LOADI, 1, 20), // R[1] := 20
            encodeABC(.OP_ADD, 2, 0, 1),  // R[2] := R[0] + R[1]
            @intFromEnum(Op.OP_RETURN1) | (@as(Instruction, 2) << POS_A), // return R[2]
        },
        .prototypes = &.{},
        .line_info = &.{},
        .max_stack_size = 4,
        .num_upvalues = 0,
        .num_params = 0,
        .is_vararg = false,
    };
    const result = try executePrototype(allocator, &proto);
    try std.testing.expectEqual(BcValue{ .integer = 30 }, result);
}

test "bytecode execution: FORLOOP" {
    const allocator = std.testing.allocator;
    // Simulate: local sum = 0; for i = 1, 5 do sum = sum + i end; return sum
    // Registers: R[0]=sum, R[1]=i (loop idx), R[2]=limit, R[3]=step
    const code = &[_]Instruction{
        encodeAsBx(.OP_LOADI, 0, 0),   // R[0] := 0 (sum)
        encodeAsBx(.OP_LOADI, 1, 1),   // R[1] := 1 (i initial)
        encodeAsBx(.OP_LOADI, 2, 5),   // R[2] := 5 (limit)
        encodeAsBx(.OP_LOADI, 3, 1),   // R[3] := 1 (step)
        encodeAsBx(.OP_FORPREP, 1, 2), // prepare loop, jump to FORLOOP+2 offset
        encodeABC(.OP_ADD, 0, 0, 4),   // R[0] := R[0] + R[4] (R[4] = loop value)
        encodeAsBx(.OP_FORLOOP, 1, 1), // loop back by 1 instruction
        @intFromEnum(Op.OP_RETURN1) | (@as(Instruction, 0) << POS_A), // return R[0]
    };
    const proto = Prototype{
        .constants = &.{},
        .code = code,
        .prototypes = &.{},
        .line_info = &.{},
        .max_stack_size = 8,
        .num_upvalues = 0,
        .num_params = 0,
        .is_vararg = false,
    };
    const result = try executePrototype(allocator, &proto);
    try std.testing.expectEqual(BcValue{ .integer = 15 }, result);
}

test "bytecode execution: LOADI values" {
    const allocator = std.testing.allocator;
    const proto = Prototype{
        .constants = &.{},
        .code = &.{
            encodeAsBx(.OP_LOADI, 0, 10),  // R[0] := 10
            encodeAsBx(.OP_LOADI, 1, 20),  // R[1] := 20
            encodeABC(.OP_ADD, 0, 0, 1),   // R[0] := R[0] + R[1]
            @intFromEnum(Op.OP_RETURN1) | (@as(Instruction, 0) << POS_A),
        },
        .prototypes = &.{},
        .line_info = &.{},
        .max_stack_size = 4,
        .num_upvalues = 0,
        .num_params = 0,
        .is_vararg = false,
    };
    const result = try executePrototype(allocator, &proto);
    try std.testing.expectEqual(BcValue{ .integer = 30 }, result);
}
