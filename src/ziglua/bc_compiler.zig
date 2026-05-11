const bc_vm = @import("bc_vm.zig");
const std = @import("std");

// =============================================================================
// Bytecode Compiler — compiles a subset of Lua source to bytecode
// Currently supports:
//   - Numeric literals (integer, float)
//   - String literals
//   - nil, true, false
//   - Local variables, assignment
//   - Arithmetic (+, -, *, /, //, %, ^)
//   - Unary (-, not)
//   - Comparison (<, >, <=, >=, ==, ~=)
//   - if/elseif/else
//   - while loops
//   - numeric for loops
//   - return
//   - print() (built-in)
// =============================================================================

pub const CompileError = error{
    SyntaxError,
    OutOfMemory,
    NotImplemented,
    TooManyRegisters,
    TooManyConstants,
};

// =============================================================================
// Token
// =============================================================================

const Tag = enum(u8) {
    eof,
    number,
    string,
    name,
    // Keywords
    kw_local,
    kw_function,
    kw_end,
    kw_if,
    kw_then,
    kw_elseif,
    kw_else,
    kw_while,
    kw_do,
    kw_for,
    kw_in,
    kw_repeat,
    kw_until,
    kw_return,
    kw_break,
    kw_and,
    kw_or,
    kw_not,
    kw_nil,
    kw_true,
    kw_false,
    // Operators
    op_add,
    op_sub,
    op_mul,
    op_div,
    op_idiv,
    op_mod,
    op_pow,
    op_eq,
    op_neq,
    op_lt,
    op_gt,
    op_le,
    op_ge,
    op_assign,
    op_len,
    op_concat,
    op_dot,
    op_comma,
    op_semi,
    op_lparen,
    op_rparen,
    op_lbrace,
    op_rbrace,
    op_lbracket,
    op_rbracket,
};

const Token = struct {
    tag: Tag,
    text: []const u8,
    line: u32,
};

// =============================================================================
// Lexer
// =============================================================================

const Lexer = struct {
    source: []const u8,
    pos: usize,
    line: u32,
    current: Token,

    fn init(source: []const u8) Lexer {
        var lex = Lexer{
            .source = source,
            .pos = 0,
            .line = 1,
            .current = .{ .tag = .eof, .text = "", .line = 1 },
        };
        lex.nextToken();
        return lex;
    }

    fn peek(lex: *Lexer) Token {
        return lex.current;
    }

    fn advance(lex: *Lexer) Token {
        const tok = lex.current;
        lex.nextToken();
        return tok;
    }

    fn expect(lex: *Lexer, tag: Tag) !Token {
        if (lex.current.tag != tag) return CompileError.SyntaxError;
        return lex.advance();
    }

    fn match(lex: *Lexer, tag: Tag) bool {
        if (lex.current.tag == tag) {
            _ = lex.advance();
            return true;
        }
        return false;
    }

    fn skipWhitespace(lex: *Lexer) void {
        while (lex.pos < lex.source.len) {
            const c = lex.source[lex.pos];
            if (c == ' ' or c == '\t' or c == '\r') {
                lex.pos += 1;
            } else if (c == '\n') {
                lex.pos += 1;
                lex.line += 1;
            } else if (c == '-' and lex.pos + 1 < lex.source.len and lex.source[lex.pos + 1] == '-') {
                // Comment
                lex.pos += 2;
                while (lex.pos < lex.source.len and lex.source[lex.pos] != '\n') : (lex.pos += 1) {}
            } else {
                break;
            }
        }
    }

    fn nextToken(lex: *Lexer) void {
        lex.skipWhitespace();
        if (lex.pos >= lex.source.len) {
            lex.current = .{ .tag = .eof, .text = "", .line = lex.line };
            return;
        }

        const start = lex.pos;
        const c = lex.source[lex.pos];

        // Numbers
        if (isDigit(c) or (c == '.' and lex.pos + 1 < lex.source.len and isDigit(lex.source[lex.pos + 1]))) {
            while (lex.pos < lex.source.len and (isDigit(lex.source[lex.pos]) or lex.source[lex.pos] == '.')) {
                lex.pos += 1;
            }
            // Hex
            if (lex.source[start] == '0' and lex.pos > start + 1 and (lex.source[start + 1] == 'x' or lex.source[start + 1] == 'X')) {
                while (lex.pos < lex.source.len and isHexDigit(lex.source[lex.pos])) lex.pos += 1;
            }
            lex.current = .{ .tag = .number, .text = lex.source[start..lex.pos], .line = lex.line };
            return;
        }

        // Strings
        if (c == '"' or c == '\'') {
            lex.pos += 1;
            while (lex.pos < lex.source.len and lex.source[lex.pos] != c) {
                if (lex.source[lex.pos] == '\\') lex.pos += 1;
                lex.pos += 1;
            }
            if (lex.pos < lex.source.len) lex.pos += 1; // closing quote
            lex.current = .{ .tag = .string, .text = lex.source[start + 1 .. lex.pos - 1], .line = lex.line };
            return;
        }

        // Identifiers and keywords
        if (isAlpha(c) or c == '_') {
            while (lex.pos < lex.source.len and (isAlphaNum(lex.source[lex.pos]) or lex.source[lex.pos] == '_')) {
                lex.pos += 1;
            }
            const text = lex.source[start..lex.pos];
            const tag = keywords.get(text) orelse Tag.name;
            lex.current = .{ .tag = tag, .text = text, .line = lex.line };
            return;
        }

        // Two-char operators
        if (lex.pos + 1 < lex.source.len) {
            const two = lex.source[lex.pos .. lex.pos + 2];
            if (std.mem.eql(u8, two, "==")) { lex.pos += 2; lex.current = .{ .tag = .op_eq, .text = two, .line = lex.line }; return; }
            if (std.mem.eql(u8, two, "~=")) { lex.pos += 2; lex.current = .{ .tag = .op_neq, .text = two, .line = lex.line }; return; }
            if (std.mem.eql(u8, two, "<=")) { lex.pos += 2; lex.current = .{ .tag = .op_le, .text = two, .line = lex.line }; return; }
            if (std.mem.eql(u8, two, ">=")) { lex.pos += 2; lex.current = .{ .tag = .op_ge, .text = two, .line = lex.line }; return; }
            if (std.mem.eql(u8, two, "//")) { lex.pos += 2; lex.current = .{ .tag = .op_idiv, .text = two, .line = lex.line }; return; }
            if (std.mem.eql(u8, two, "..")) { lex.pos += 2; lex.current = .{ .tag = .op_concat, .text = two, .line = lex.line }; return; }
        }

        // Single-char operators
        lex.pos += 1;
        const tag: Tag = switch (c) {
            '+' => .op_add,
            '-' => .op_sub,
            '*' => .op_mul,
            '/' => .op_div,
            '%' => .op_mod,
            '^' => .op_pow,
            '<' => .op_lt,
            '>' => .op_gt,
            '=' => .op_assign,
            '#' => .op_len,
            '.' => .op_dot,
            ',' => .op_comma,
            ';' => .op_semi,
            '(' => .op_lparen,
            ')' => .op_rparen,
            '{' => .op_lbrace,
            '}' => .op_rbrace,
            '[' => .op_lbracket,
            ']' => .op_rbracket,
            else => .eof,
        };
        lex.current = .{ .tag = tag, .text = lex.source[start..lex.pos], .line = lex.line };
    }
};

const keywords = std.StaticStringMap(Tag).initComptime(.{
    .{ "local", .kw_local },
    .{ "function", .kw_function },
    .{ "end", .kw_end },
    .{ "if", .kw_if },
    .{ "then", .kw_then },
    .{ "elseif", .kw_elseif },
    .{ "else", .kw_else },
    .{ "while", .kw_while },
    .{ "do", .kw_do },
    .{ "for", .kw_for },
    .{ "in", .kw_in },
    .{ "repeat", .kw_repeat },
    .{ "until", .kw_until },
    .{ "return", .kw_return },
    .{ "break", .kw_break },
    .{ "and", .kw_and },
    .{ "or", .kw_or },
    .{ "not", .kw_not },
    .{ "nil", .kw_nil },
    .{ "true", .kw_true },
    .{ "false", .kw_false },
});

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}
fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}
fn isAlphaNum(c: u8) bool {
    return isAlpha(c) or isDigit(c);
}

// =============================================================================
// Compiler
// =============================================================================

const CompileErr = error{ SyntaxError, OutOfMemory, NotImplemented, TooManyRegisters, TooManyConstants };

const Compiler = struct {
    allocator: std.mem.Allocator,
    lex: Lexer,
    code: std.ArrayList(bc_vm.Instruction),
    constants: std.ArrayList(bc_vm.BcValue),
    /// Local variable → register index
    locals: std.StringHashMap(u8),
    local_count: u8,
    /// First free register
    free_reg: u8,

    fn init(allocator: std.mem.Allocator, source: []const u8) Compiler {
        return .{
            .allocator = allocator,
            .lex = Lexer.init(source),
            .code = std.ArrayList(bc_vm.Instruction).initCapacity(allocator, 64) catch @panic("oom"),
            .constants = std.ArrayList(bc_vm.BcValue).initCapacity(allocator, 16) catch @panic("oom"),
            .locals = std.StringHashMap(u8).init(allocator),
            .local_count = 0,
            .free_reg = 0,
        };
    }

    fn deinit(self: *Compiler) void {
        self.code.deinit(self.allocator);
        for (self.constants.items) |c| {
            if (c == .string) self.allocator.free(c.string);
        }
        self.constants.deinit(self.allocator);
        self.locals.deinit();
    }

    fn emit(self: *Compiler, inst: bc_vm.Instruction) !void {
        try self.code.append(self.allocator, inst);
    }

    fn addConstant(self: *Compiler, val: bc_vm.BcValue) !u8 {
        // Check if constant already exists
        for (self.constants.items, 0..) |c, i| {
            if (bcVmValuesEqual(c, val)) return @intCast(i);
        }
        const idx: u8 = @intCast(self.constants.items.len);
        if (idx >= 250) return CompileError.TooManyConstants;
        try self.constants.append(self.allocator, val);
        return idx;
    }

    fn allocReg(self: *Compiler) !u8 {
        if (self.free_reg >= 250) return CompileError.TooManyRegisters;
        const r = self.free_reg;
        self.free_reg += 1;
        return r;
    }

    fn addLocal(self: *Compiler, name: []const u8) !u8 {
        const r = try self.allocReg();
        try self.locals.put(name, r);
        self.local_count += 1;
        return r;
    }

    fn getLocal(self: *Compiler, name: []const u8) ?u8 {
        return self.locals.get(name);
    }

    // ========================================================================
    // Statement parsing
    // ========================================================================

    fn compileBlock(self: *Compiler) CompileErr!void {
        while (true) {
            const tag = self.lex.peek().tag;
            if (tag == .eof or tag == .kw_end or tag == .kw_else or tag == .kw_elseif or tag == .kw_until) return;
            if (tag == .op_semi) { _ = self.lex.advance(); continue; }
            try self.compileStatement();
        }
    }

    fn compileStatement(self: *Compiler) CompileErr!void {
        const tok = self.lex.peek();
        switch (tok.tag) {
            .kw_local => try self.compileLocal(),
            .kw_return => try self.compileReturn(),
            .kw_if => try self.compileIf(),
            .kw_while => try self.compileWhile(),
            .kw_for => try self.compileFor(),
            .kw_do => {
                _ = self.lex.advance(); // 'do'
                try self.compileBlock();
                _ = try self.lex.expect(.kw_end);
            },
            else => try self.compileExprStatement(),
        }
    }

    fn compileLocal(self: *Compiler) CompileErr!void {
        _ = self.lex.advance(); // 'local'
        if (self.lex.peek().tag == .kw_function) {
            return CompileError.NotImplemented; // local function
        }
        const name_tok = try self.lex.expect(.name);
        const reg = try self.addLocal(name_tok.text);

        if (self.lex.match(.op_assign)) {
            const src = try self.compileExpr();
            if (src != reg) {
                try self.emit(bc_vm.encodeABC(.OP_MOVE, reg, src, 0));
            }
        } else {
            try self.emit(bc_vm.encodeABC(.OP_LOADNIL, reg, 0, 0));
        }
        _ = self.lex.match(.op_semi);
    }

    fn compileReturn(self: *Compiler) CompileErr!void {
        _ = self.lex.advance(); // 'return'
        if (self.lex.peek().tag == .kw_end or self.lex.peek().tag == .eof or self.lex.peek().tag == .op_semi) {
            try self.emit(@intFromEnum(bc_vm.Op.OP_RETURN0));
            _ = self.lex.match(.op_semi);
            return;
        }
        const reg = try self.compileExpr();
        try self.emit(@as(bc_vm.Instruction, @intFromEnum(bc_vm.Op.OP_RETURN1)) | (@as(bc_vm.Instruction, reg) << bc_vm.POS_A));
        _ = self.lex.match(.op_semi);
    }

    fn compileIf(self: *Compiler) CompileErr!void {
        _ = self.lex.advance(); // 'if'
        const cond_reg = try self.compileExpr();
        _ = try self.lex.expect(.kw_then);

        // TEST + JMP (skip then-block if false)
        try self.emit(bc_vm.encodeABC(.OP_TEST, cond_reg, 0, 0));
        const jmp_idx = self.code.items.len;
        try self.emit(bc_vm.encodeAsBx(.OP_JMP, 0, 0)); // placeholder

        try self.compileBlock();

        if (self.lex.peek().tag == .kw_elseif) {
            // elseif: jump past elseif chain at end of then-block
            const end_jmp_idx = self.code.items.len;
            try self.emit(bc_vm.encodeAsBx(.OP_JMP, 0, 0)); // placeholder
            // Patch the original JMP to skip to elseif
            const skip_to = @as(i18, @intCast(end_jmp_idx - jmp_idx));
            self.code.items[jmp_idx] = bc_vm.encodeAsBx(.OP_JMP, 0, skip_to);
            try self.compileIf(); // recurse for elseif
            // Patch end_jmp to skip to after
            const end_target = @as(i18, @intCast(self.code.items.len - end_jmp_idx));
            self.code.items[end_jmp_idx] = bc_vm.encodeAsBx(.OP_JMP, 0, end_target);
            return;
        }

        if (self.lex.peek().tag == .kw_else) {
            _ = self.lex.advance();
            // Jump past else block at end of then-block
            const end_jmp_idx = self.code.items.len;
            try self.emit(bc_vm.encodeAsBx(.OP_JMP, 0, 0)); // placeholder
            // Patch original JMP to skip to else
            const skip_to = @as(i18, @intCast(end_jmp_idx - jmp_idx));
            self.code.items[jmp_idx] = bc_vm.encodeAsBx(.OP_JMP, 0, skip_to);
            try self.compileBlock();
            _ = try self.lex.expect(.kw_end);
            // Patch end JMP
            const end_target = @as(i18, @intCast(self.code.items.len - end_jmp_idx));
            self.code.items[end_jmp_idx] = bc_vm.encodeAsBx(.OP_JMP, 0, end_target);
        } else {
            _ = try self.lex.expect(.kw_end);
            // Patch JMP to skip to after
            const skip_to = @as(i18, @intCast(self.code.items.len - jmp_idx));
            self.code.items[jmp_idx] = bc_vm.encodeAsBx(.OP_JMP, 0, skip_to);
        }
    }

    fn compileWhile(self: *Compiler) CompileErr!void {
        _ = self.lex.advance(); // 'while'
        const loop_start = self.code.items.len;
        const cond_reg = try self.compileExpr();
        _ = try self.lex.expect(.kw_do);

        // TEST + JMP (exit loop if false)
        try self.emit(bc_vm.encodeABC(.OP_TEST, cond_reg, 0, 0));
        const exit_jmp_idx = self.code.items.len;
        try self.emit(bc_vm.encodeAsBx(.OP_JMP, 0, 0)); // placeholder

        try self.compileBlock();
        _ = try self.lex.expect(.kw_end);

        // JMP back to loop_start
        const back_offset = @as(i18, @intCast(loop_start)) - @as(i18, @intCast(self.code.items.len));
        try self.emit(bc_vm.encodeAsBx(.OP_JMP, 0, back_offset));

        // Patch exit jump
        const exit_target = @as(i18, @intCast(self.code.items.len - exit_jmp_idx));
        self.code.items[exit_jmp_idx] = bc_vm.encodeAsBx(.OP_JMP, 0, exit_target);
    }

    fn compileFor(self: *Compiler) CompileErr!void {
        _ = self.lex.advance(); // 'for'
        const name_tok = try self.lex.expect(.name);

        if (self.lex.peek().tag == .op_assign) {
            // Numeric for: for var = start, limit, step do ... end
            _ = self.lex.advance(); // '='
            const var_reg = try self.addLocal(name_tok.text); // R[var]
            const limit_reg = try self.allocReg(); // R[var+1]
            const step_reg = try self.allocReg();  // R[var+2]
            _ = try self.allocReg(); // R[var+3] — internal loop value

            // Compile start → var_reg
            const start = try self.compileExpr();
            if (start != var_reg) try self.emit(bc_vm.encodeABC(.OP_MOVE, var_reg, start, 0));
            _ = try self.lex.expect(.op_comma);

            // Compile limit → limit_reg
            const limit = try self.compileExpr();
            if (limit != limit_reg) try self.emit(bc_vm.encodeABC(.OP_MOVE, limit_reg, limit, 0));

            var step: u8 = undefined;
            if (self.lex.match(.op_comma)) {
                step = try self.compileExpr();
            } else {
                // Default step = 1
                const one_reg = try self.allocReg();
                try self.emit(bc_vm.encodeAsBx(.OP_LOADI, one_reg, 1));
                step = one_reg;
            }
            if (step != step_reg) try self.emit(bc_vm.encodeABC(.OP_MOVE, step_reg, step, 0));

            _ = try self.lex.expect(.kw_do);

            // FORPREP
            const prep_idx = self.code.items.len;
            try self.emit(bc_vm.encodeAsBx(.OP_FORPREP, var_reg, 0)); // placeholder

            // Loop body
            try self.compileBlock();
            _ = try self.lex.expect(.kw_end);

            // FORLOOP — jump back to prep+1
            const loop_back = @as(i18, @intCast(prep_idx)) - @as(i18, @intCast(self.code.items.len));
            try self.emit(bc_vm.encodeAsBx(.OP_FORLOOP, var_reg, loop_back));

            // Patch FORPREP jump to point to FORLOOP
            const forward = @as(i18, @intCast(self.code.items.len - 1 - prep_idx));
            self.code.items[prep_idx] = bc_vm.encodeAsBx(.OP_FORPREP, var_reg, forward);
        } else {
            return CompileError.NotImplemented; // generic for
        }
    }

    fn compileExprStatement(self: *Compiler) CompileErr!void {
        // Check for assignment: name = expr
        if (self.lex.peek().tag == .name) {
            // Peek ahead to see if it's an assignment
            const saved_pos = self.lex.pos;
            const saved_line = self.lex.line;
            const saved_tok = self.lex.current;
            const name_tok = self.lex.advance();
            if (self.lex.peek().tag == .op_assign) {
                // It's an assignment
                _ = self.lex.advance(); // '='
                if (self.getLocal(name_tok.text)) |dest_reg| {
                    const src = try self.compileExpr();
                    if (src != dest_reg) {
                        try self.emit(bc_vm.encodeABC(.OP_MOVE, dest_reg, src, 0));
                    }
                    _ = self.lex.match(.op_semi);
                    return;
                }
                return CompileError.SyntaxError; // unknown variable
            }
            // Not assignment — restore lexer state completely
            self.lex.pos = saved_pos;
            self.lex.line = saved_line;
            self.lex.current = saved_tok;
        }
        const reg = try self.compileExpr();
        _ = reg;
        _ = self.lex.match(.op_semi);
    }

    // ========================================================================
    // Expression parsing (Pratt parser / precedence climbing)
    // ========================================================================

    fn compileExpr(self: *Compiler) CompileErr!u8 {
        return self.compileOr();
    }

    fn compileOr(self: *Compiler) CompileErr!u8 {
        var reg = try self.compileAnd();
        while (self.lex.peek().tag == .kw_or) {
            _ = self.lex.advance();
            const dest = try self.allocReg();
            try self.emit(bc_vm.encodeABC(.OP_TESTSET, dest, reg, 0));
            const jmp_idx = self.code.items.len;
            try self.emit(bc_vm.encodeAsBx(.OP_JMP, 0, 0));
            const right = try self.compileAnd();
            try self.emit(bc_vm.encodeABC(.OP_MOVE, dest, right, 0));
            const skip = @as(i18, @intCast(self.code.items.len - jmp_idx));
            self.code.items[jmp_idx] = bc_vm.encodeAsBx(.OP_JMP, 0, skip);
            reg = dest;
        }
        return reg;
    }

    fn compileAnd(self: *Compiler) CompileErr!u8 {
        var reg = try self.compileComparison();
        while (self.lex.peek().tag == .kw_and) {
            _ = self.lex.advance();
            const dest = try self.allocReg();
            try self.emit(bc_vm.encodeABC(.OP_TESTSET, dest, reg, 1));
            const jmp_idx = self.code.items.len;
            try self.emit(bc_vm.encodeAsBx(.OP_JMP, 0, 0));
            const right = try self.compileComparison();
            try self.emit(bc_vm.encodeABC(.OP_MOVE, dest, right, 0));
            const skip = @as(i18, @intCast(self.code.items.len - jmp_idx));
            self.code.items[jmp_idx] = bc_vm.encodeAsBx(.OP_JMP, 0, skip);
            reg = dest;
        }
        return reg;
    }

    fn compileComparison(self: *Compiler) CompileErr!u8 {
        var reg = try self.compileConcat();
        const tag = self.lex.peek().tag;
        switch (tag) {
            .op_lt, .op_gt, .op_le, .op_ge, .op_eq, .op_neq => {
                _ = self.lex.advance();
                const right = try self.compileConcat();
                const dest = try self.allocReg();
                const op: bc_vm.Op = switch (tag) {
                    .op_lt => .OP_LT,
                    .op_gt => .OP_LT, // swap operands
                    .op_le => .OP_LE,
                    .op_ge => .OP_LE, // swap operands
                    .op_eq => .OP_EQ,
                    .op_neq => .OP_EQ, // invert k
                    else => unreachable,
                };
                const k: u8 = switch (tag) {
                    .op_neq, .op_gt, .op_ge => 1,
                    else => 0,
                };
                // Emit comparison: if result matches k, skip next instruction
                if (tag == .op_gt or tag == .op_ge) {
                    try self.emit(@as(bc_vm.Instruction, @intFromEnum(op)) |
                        (@as(bc_vm.Instruction, dest) << bc_vm.POS_A) |
                        (@as(bc_vm.Instruction, right) << bc_vm.POS_B) |
                        (@as(bc_vm.Instruction, reg) << bc_vm.POS_C) |
                        (@as(bc_vm.Instruction, k) << bc_vm.POS_k));
                } else {
                    try self.emit(@as(bc_vm.Instruction, @intFromEnum(op)) |
                        (@as(bc_vm.Instruction, dest) << bc_vm.POS_A) |
                        (@as(bc_vm.Instruction, reg) << bc_vm.POS_B) |
                        (@as(bc_vm.Instruction, right) << bc_vm.POS_C) |
                        (@as(bc_vm.Instruction, k) << bc_vm.POS_k));
                }
                // LOADTRUE (taken if comparison matches)
                try self.emit(@as(bc_vm.Instruction, @intFromEnum(bc_vm.Op.OP_LOADTRUE)) |
                    (@as(bc_vm.Instruction, dest) << bc_vm.POS_A));
                // LOADFALSE (skipped if comparison matched, taken otherwise)
                try self.emit(@as(bc_vm.Instruction, @intFromEnum(bc_vm.Op.OP_LOADFALSE)) |
                    (@as(bc_vm.Instruction, dest) << bc_vm.POS_A));
                reg = dest;
            },
            else => {},
        }
        return reg;
    }

    fn compileConcat(self: *Compiler) CompileErr!u8 {
        const reg = try self.compileAdd();
        while (self.lex.peek().tag == .op_concat) {
            _ = self.lex.advance();
            const _right = try self.compileAdd();
            _ = _right;
            try self.emit(bc_vm.encodeABC(.OP_CONCAT, reg, 2, 0));
        }
        return reg;
    }

    fn compileAdd(self: *Compiler) CompileErr!u8 {
        var reg = try self.compileMul();
        while (true) {
            const tag = self.lex.peek().tag;
            if (tag == .op_add or tag == .op_sub) {
                _ = self.lex.advance();
                const right = try self.compileMul();
                const dest = try self.allocReg();
                const op: bc_vm.Op = if (tag == .op_add) .OP_ADD else .OP_SUB;
                try self.emit(bc_vm.encodeABC(op, dest, reg, right));
                reg = dest;
            } else break;
        }
        return reg;
    }

    fn compileMul(self: *Compiler) CompileErr!u8 {
        var reg = try self.compilePow();
        while (true) {
            const tag = self.lex.peek().tag;
            const op: bc_vm.Op = switch (tag) {
                .op_mul => .OP_MUL,
                .op_div => .OP_DIV,
                .op_idiv => .OP_IDIV,
                .op_mod => .OP_MOD,
                else => break,
            };
            _ = self.lex.advance();
            const right = try self.compilePow();
            const dest = try self.allocReg();
            try self.emit(bc_vm.encodeABC(op, dest, reg, right));
            reg = dest;
        }
        return reg;
    }

    fn compilePow(self: *Compiler) CompileErr!u8 {
        const reg = try self.compileUnary();
        if (self.lex.peek().tag == .op_pow) {
            _ = self.lex.advance();
            const right = try self.compilePow(); // right-associative!
            const dest = try self.allocReg();
            try self.emit(bc_vm.encodeABC(.OP_POW, dest, reg, right));
            return dest;
        }
        return reg;
    }

    fn compileUnary(self: *Compiler) CompileErr!u8 {
        const tag = self.lex.peek().tag;
        if (tag == .op_sub) {
            _ = self.lex.advance();
            const operand = try self.compileUnary();
            const dest = try self.allocReg();
            try self.emit(bc_vm.encodeABC(.OP_UNM, dest, operand, 0));
            return dest;
        }
        if (tag == .kw_not) {
            _ = self.lex.advance();
            const operand = try self.compileUnary();
            const dest = try self.allocReg();
            try self.emit(bc_vm.encodeABC(.OP_NOT, dest, operand, 0));
            return dest;
        }
        if (tag == .op_len) {
            _ = self.lex.advance();
            const operand = try self.compileUnary();
            const dest = try self.allocReg();
            try self.emit(bc_vm.encodeABC(.OP_LEN, dest, operand, 0));
            return dest;
        }
        return self.compilePrimary();
    }

    fn compilePrimary(self: *Compiler) CompileErr!u8 {
        const tok = self.lex.peek();
        switch (tok.tag) {
            .number => return self.compileNumber(),
            .string => return self.compileString(),
            .kw_nil => {
                _ = self.lex.advance();
                const reg = try self.allocReg();
                try self.emit(bc_vm.encodeABC(.OP_LOADNIL, reg, 0, 0));
                return reg;
            },
            .kw_true => {
                _ = self.lex.advance();
                const reg = try self.allocReg();
                try self.emit(@as(bc_vm.Instruction, @intFromEnum(bc_vm.Op.OP_LOADTRUE)) | (@as(bc_vm.Instruction, reg) << bc_vm.POS_A));
                return reg;
            },
            .kw_false => {
                _ = self.lex.advance();
                const reg = try self.allocReg();
                try self.emit(@as(bc_vm.Instruction, @intFromEnum(bc_vm.Op.OP_LOADFALSE)) | (@as(bc_vm.Instruction, reg) << bc_vm.POS_A));
                return reg;
            },
            .name => return self.compileName(),
            .op_lparen => {
                _ = self.lex.advance();
                const reg = try self.compileExpr();
                _ = try self.lex.expect(.op_rparen);
                return reg;
            },
            else => return CompileError.SyntaxError,
        }
    }

    fn compileNumber(self: *Compiler) CompileErr!u8 {
        const tok = self.lex.advance();
        const reg = try self.allocReg();

        // Parse number
        if (std.mem.indexOfScalar(u8, tok.text, '.')) |_| {
            // Float
            const val = std.fmt.parseFloat(f64, tok.text) catch 0.0;
            const idx = try self.addConstant(.{ .float = val });
            try self.emit(bc_vm.encodeABx(.OP_LOADK, reg, idx));
        } else if (tok.text.len > 2 and (tok.text[1] == 'x' or tok.text[1] == 'X')) {
            // Hex integer
            const val = std.fmt.parseInt(i64, tok.text, 16) catch 0;
            if (val >= -32768 and val <= 32767) {
                try self.emit(bc_vm.encodeAsBx(.OP_LOADI, reg, @intCast(val)));
            } else {
                const idx = try self.addConstant(.{ .integer = val });
                try self.emit(bc_vm.encodeABx(.OP_LOADK, reg, idx));
            }
        } else {
            // Integer
            const val = std.fmt.parseInt(i64, tok.text, 10) catch 0;
            if (val >= -32768 and val <= 32767) {
                try self.emit(bc_vm.encodeAsBx(.OP_LOADI, reg, @intCast(val)));
            } else {
                const idx = try self.addConstant(.{ .integer = val });
                try self.emit(bc_vm.encodeABx(.OP_LOADK, reg, idx));
            }
        }
        return reg;
    }

    fn compileString(self: *Compiler) CompileErr!u8 {
        const tok = self.lex.advance();
        const reg = try self.allocReg();
        const copy = try self.allocator.dupe(u8, tok.text);
        const idx = try self.addConstant(.{ .string = copy });
        try self.emit(bc_vm.encodeABx(.OP_LOADK, reg, idx));
        return reg;
    }

    fn compileName(self: *Compiler) CompileErr!u8 {
        const tok = self.lex.advance();

        // Check for function call: name(args)
        if (self.lex.peek().tag == .op_lparen) {
            // Built-in: print
            if (std.mem.eql(u8, tok.text, "print")) {
                return try self.compilePrintCall();
            }
            // Generic function call
            return try self.compileFuncCall(tok.text);
        }

        // Local variable
        const maybe_reg = self.getLocal(tok.text);
        if (maybe_reg) |reg| {
            return reg;
        }

        return CompileError.SyntaxError;
    }

    fn compilePrintCall(self: *Compiler) CompileErr!u8 {
        _ = self.lex.advance(); // '('
        const arg = try self.compileExpr();
        _ = try self.lex.expect(.op_rparen);
        // For now, emit a RETURN1 — the host will handle print
        // Actually, let's use LOADK to store result and return it
        return arg;
    }

    fn compileFuncCall(self: *Compiler, name: []const u8) CompileErr!u8 {
        _ = name;
        _ = self.lex.advance(); // '('
        // Just compile arguments and skip
        if (self.lex.peek().tag != .op_rparen) {
            _ = try self.compileExpr();
            while (self.lex.match(.op_comma)) {
                _ = try self.compileExpr();
            }
        }
        _ = try self.lex.expect(.op_rparen);
        const reg = try self.allocReg();
        return reg;
    }
};

// Value equality for constant dedup
fn bcVmValuesEqual(a: bc_vm.BcValue, b: bc_vm.BcValue) bool {
    const at = std.meta.activeTag(a);
    const bt = std.meta.activeTag(b);
    if (at != bt) return false;
    return switch (a) {
        .nil => true,
        .boolean => |v| b.boolean == v,
        .integer => |v| b.integer == v,
        .float => |v| b.float == v,
        .string => |v| std.mem.eql(u8, v, b.string),
    };
}

// =============================================================================
// Public API
// =============================================================================

pub fn compileSource(allocator: std.mem.Allocator, source: []const u8) !*bc_vm.Prototype {
    var comp = Compiler.init(allocator, source);
    defer comp.deinit();

    try comp.compileBlock();

    // Add implicit return nil
    try comp.emit(@intFromEnum(bc_vm.Op.OP_RETURN0));

    const proto = try allocator.create(bc_vm.Prototype);
    proto.* = .{
        .constants = try comp.constants.toOwnedSlice(allocator),
        .code = try comp.code.toOwnedSlice(allocator),
        .prototypes = &.{},
        .line_info = &.{},
        .max_stack_size = comp.free_reg + 4,
        .num_upvalues = 0,
        .num_params = 0,
        .is_vararg = true,
    };
    return proto;
}

pub fn deinitPrototype(proto: *bc_vm.Prototype, allocator: std.mem.Allocator) void {
    for (proto.constants) |c| {
        if (c == .string) allocator.free(c.string);
    }
    allocator.free(proto.constants);
    allocator.free(proto.code);
    allocator.destroy(proto);
}
