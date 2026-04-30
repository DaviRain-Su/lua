const std = @import("std");
const advanced_hooks = @import("advanced_hooks.zig");

pub const VmState = enum { pass, unsupported, runtime_error };

pub const VmResult = struct {
    state: VmState,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
    unsupported_reason: ?[]const u8,
};

const TokenTag = enum {
    eof,
    ident,
    number,
    string,
    keyword,
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    comma,
    semi,
    dot,
    coloncolon,
    assign,
    plus,
    minus,
    star,
    slash,
    floor_div,
    percent,
    concat,
    len,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    amp,
    pipe,
    tilde,
    shl,
    shr,
    ellipsis,
};

const Token = struct {
    tag: TokenTag,
    lexeme: []const u8,
    line: usize,
};

const Function = struct {
    name: []const u8,
    params: []const []const u8,
    vararg: bool,
    body_start: usize,
    body_end: usize,
    env: ?*Table,
    lexical_scope_len: usize,
};

const Builtin = enum { print, select };

const ValueTag = enum { nil, boolean, integer, float, string, table, function, builtin };

const Value = union(ValueTag) {
    nil: void,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    table: *Table,
    function: *Function,
    builtin: Builtin,

    fn isTruthy(self: Value) bool {
        return switch (self) {
            .nil => false,
            .boolean => |b| b,
            else => true,
        };
    }

    fn isNil(self: Value) bool {
        return switch (self) {
            .nil => true,
            else => false,
        };
    }
};

const Table = struct {
    array: std.ArrayList(Value),
    integers: std.AutoHashMap(i64, Value),
    strings: std.StringHashMap(Value),

    fn create(allocator: std.mem.Allocator) !*Table {
        const table = try allocator.create(Table);
        table.* = .{
            .array = .empty,
            .integers = std.AutoHashMap(i64, Value).init(allocator),
            .strings = std.StringHashMap(Value).init(allocator),
        };
        return table;
    }

    fn appendArray(self: *Table, allocator: std.mem.Allocator, value: Value) !void {
        try self.array.append(allocator, value);
    }

    fn setString(self: *Table, key: []const u8, value: Value) !void {
        try self.strings.put(key, value);
    }

    fn getString(self: *Table, key: []const u8) Value {
        return self.strings.get(key) orelse .{ .nil = {} };
    }

    fn setIndex(self: *Table, allocator: std.mem.Allocator, index: i64, value: Value) !void {
        if (index < 1) {
            try self.integers.put(index, value);
            return;
        }
        const idx: usize = @intCast(index - 1);
        while (self.array.items.len <= idx) {
            try self.array.append(allocator, .{ .nil = {} });
        }
        self.array.items[idx] = value;
    }

    fn getIndex(self: *Table, index: i64) Value {
        if (index < 1) return self.integers.get(index) orelse .{ .nil = {} };
        const idx: usize = @intCast(index - 1);
        if (idx >= self.array.items.len) return .{ .nil = {} };
        return self.array.items[idx];
    }

    fn length(self: *Table) i64 {
        var n: usize = 0;
        while (n < self.array.items.len and !self.array.items[n].isNil()) : (n += 1) {}
        return @intCast(n);
    }
};

const Scope = struct {
    vars: std.StringHashMap(Value),
    varargs: []const Value,
    has_varargs: bool,
};

const CallFrame = struct {
    scope_start: usize,
    lexical_scope_len: usize,
    env: ?*Table,
};

const ExecSignal = union(enum) {
    normal,
    break_loop,
    returned: []const Value,
};

const TargetKind = enum { name, string_field, index };

const AssignTarget = struct {
    kind: TargetKind,
    name: []const u8,
    table: ?*Table = null,
    key_string: []const u8 = "",
    key_index: i64 = 0,
};

const Vm = struct {
    allocator: std.mem.Allocator,
    tokens: []const Token,
    stdout: std.Io.Writer.Allocating,
    scopes: std.ArrayList(Scope),
    frames: std.ArrayList(CallFrame),

    fn init(allocator: std.mem.Allocator, tokens: []const Token) !Vm {
        return initWithVarargs(allocator, tokens, &.{});
    }

    fn initWithVarargs(allocator: std.mem.Allocator, tokens: []const Token, varargs: []const Value) !Vm {
        var vm = Vm{
            .allocator = allocator,
            .tokens = tokens,
            .stdout = std.Io.Writer.Allocating.init(allocator),
            .scopes = .empty,
            .frames = .empty,
        };
        try vm.pushScope(varargs, varargs.len > 0);
        const default_env = try Table.create(allocator);
        try default_env.setString("print", .{ .builtin = .print });
        try default_env.setString("select", .{ .builtin = .select });
        try vm.declare("_ENV", .{ .table = default_env });
        return vm;
    }

    fn pushScope(self: *Vm, varargs: []const Value, has_varargs: bool) !void {
        try self.scopes.append(self.allocator, .{
            .vars = std.StringHashMap(Value).init(self.allocator),
            .varargs = varargs,
            .has_varargs = has_varargs,
        });
    }

    fn popScope(self: *Vm) void {
        _ = self.scopes.pop();
    }

    fn currentScope(self: *Vm) *Scope {
        return &self.scopes.items[self.scopes.items.len - 1];
    }

    fn declare(self: *Vm, name: []const u8, value: Value) !void {
        try self.currentScope().vars.put(name, value);
    }

    fn assignName(self: *Vm, name: []const u8, value: Value) !void {
        if (self.activeFrame()) |frame| {
            if (self.assignNameInScopeRange(name, value, self.scopes.items.len, frame.scope_start)) return;
            if (self.assignNameInScopeRange(name, value, @min(frame.lexical_scope_len, self.scopes.items.len), 0)) return;
            if (self.environmentForFrame(frame)) |env| {
                try env.setString(name, value);
                return;
            }
        } else {
            if (self.assignNameInScopeRange(name, value, self.scopes.items.len, 0)) return;
            if (self.currentEnvironment()) |env| {
                try env.setString(name, value);
                return;
            }
        }
        try self.scopes.items[0].vars.put(name, value);
    }

    fn lookup(self: *Vm, name: []const u8) Value {
        if (self.activeFrame()) |frame| {
            if (self.lookupNameInScopeRange(name, self.scopes.items.len, frame.scope_start)) |value| return value;
            if (self.lookupNameInScopeRange(name, @min(frame.lexical_scope_len, self.scopes.items.len), 0)) |value| return value;
            if (self.environmentForFrame(frame)) |env| {
                const value = env.getString(name);
                if (!value.isNil()) return value;
            }
        } else {
            if (self.lookupNameInScopeRange(name, self.scopes.items.len, 0)) |value| return value;
            if (self.currentEnvironment()) |env| {
                const value = env.getString(name);
                if (!value.isNil()) return value;
            }
        }
        return .{ .nil = {} };
    }

    fn lookupNameInScopeRange(self: *Vm, name: []const u8, start_exclusive: usize, lower_inclusive: usize) ?Value {
        if (start_exclusive == 0 or lower_inclusive >= self.scopes.items.len) return null;
        var i = @min(start_exclusive, self.scopes.items.len);
        while (i > lower_inclusive) {
            i -= 1;
            if (self.scopes.items[i].vars.get(name)) |value| return value;
        }
        return null;
    }

    fn assignNameInScopeRange(self: *Vm, name: []const u8, value: Value, start_exclusive: usize, lower_inclusive: usize) bool {
        if (start_exclusive == 0 or lower_inclusive >= self.scopes.items.len) return false;
        var i = @min(start_exclusive, self.scopes.items.len);
        while (i > lower_inclusive) {
            i -= 1;
            if (self.scopes.items[i].vars.getPtr(name)) |slot| {
                slot.* = value;
                return true;
            }
        }
        return false;
    }

    fn environmentInScopeRange(self: *Vm, start_exclusive: usize, lower_inclusive: usize) ?*Table {
        if (start_exclusive == 0 or lower_inclusive >= self.scopes.items.len) return null;
        var i = @min(start_exclusive, self.scopes.items.len);
        while (i > lower_inclusive) {
            i -= 1;
            if (self.scopes.items[i].vars.get("_ENV")) |env| {
                if (env == .table) return env.table;
            }
        }
        return null;
    }

    fn currentEnvironment(self: *Vm) ?*Table {
        return self.environmentInScopeRange(self.scopes.items.len, 0);
    }

    fn activeFrame(self: *Vm) ?CallFrame {
        if (self.frames.items.len == 0) return null;
        return self.frames.items[self.frames.items.len - 1];
    }

    fn environmentForFrame(self: *Vm, frame: CallFrame) ?*Table {
        if (self.environmentInScopeRange(self.scopes.items.len, frame.scope_start)) |env| return env;
        if (frame.env) |env| return env;
        return self.environmentInScopeRange(@min(frame.lexical_scope_len, self.scopes.items.len), 0);
    }

    fn captureEnvironmentForDefinition(self: *Vm) ?*Table {
        if (self.activeFrame()) |frame| return self.environmentForFrame(frame);
        return self.currentEnvironment();
    }

    fn currentVarargs(self: *Vm) []const Value {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].has_varargs) return self.scopes.items[i].varargs;
        }
        return &.{};
    }

    fn writeValue(self: *Vm, value: Value) !void {
        switch (value) {
            .nil => try self.stdout.writer.writeAll("nil"),
            .boolean => |b| try self.stdout.writer.writeAll(if (b) "true" else "false"),
            .integer => |i| try self.stdout.writer.print("{d}", .{i}),
            .float => |f| try self.stdout.writer.print("{d}", .{f}),
            .string => |s| try self.stdout.writer.writeAll(s),
            .table => try self.stdout.writer.writeAll("table"),
            .function => try self.stdout.writer.writeAll("function"),
            .builtin => try self.stdout.writer.writeAll("function"),
        }
    }
};

const Parser = struct {
    vm: *Vm,
    pos: usize,
    limit: usize,
    evaluate: bool,

    fn parseBlock(self: *Parser) !ExecSignal {
        while (self.pos < self.limit and self.peek().tag != .eof) {
            if (self.peekKeyword("end") or self.peekKeyword("until") or self.peekKeyword("else")) break;
            if (self.match(.semi)) continue;
            if (self.peek().tag == .coloncolon) {
                try self.skipLabel();
                continue;
            }
            const signal = try self.statement();
            switch (signal) {
                .normal => {},
                .break_loop, .returned => return signal,
            }
        }
        return .normal;
    }

    fn statement(self: *Parser) !ExecSignal {
        if (self.matchKeyword("local")) return self.localStatement();
        if (self.matchKeyword("return")) return self.returnStatement();
        if (self.matchKeyword("do")) return self.doBlock();
        if (self.matchKeyword("if")) return self.ifStatement();
        if (self.matchKeyword("while")) return self.whileStatement();
        if (self.matchKeyword("repeat")) return self.repeatStatement();
        if (self.matchKeyword("for")) return self.forStatement();
        if (self.matchKeyword("goto")) return self.gotoStatement();
        if (self.matchKeyword("break")) return .break_loop;
        if (self.peek().tag == .ident and self.peekOffset(1).tag == .lparen) {
            _ = try self.expressionValues();
            return .normal;
        }
        if (self.peek().tag == .ident) return self.assignmentStatement();
        if (self.peek().tag == .eof) return .normal;
        return error.UnsupportedFeature;
    }

    fn localStatement(self: *Parser) !ExecSignal {
        if (self.matchKeyword("function")) return self.localFunctionStatement();
        var names: std.ArrayList([]const u8) = .empty;
        while (true) {
            const name = try self.consumeIdent();
            try names.append(self.vm.allocator, name);
            if (!self.match(.comma)) break;
        }
        var values: std.ArrayList(Value) = .empty;
        if (self.match(.assign)) {
            try self.parseExpressionList(&values);
        }
        for (names.items, 0..) |name, i| {
            const value = if (i < values.items.len) values.items[i] else Value{ .nil = {} };
            try self.vm.declare(name, value);
        }
        return .normal;
    }

    fn skipLabel(self: *Parser) !void {
        try self.consume(.coloncolon);
        _ = try self.consumeIdent();
        try self.consume(.coloncolon);
    }

    fn gotoStatement(self: *Parser) !ExecSignal {
        const label = try self.consumeIdent();
        if (self.findLabel(self.pos, self.limit, label)) |idx| {
            self.pos = idx;
            try self.skipLabel();
            return .normal;
        }
        if (self.findLabel(0, self.pos, label)) |idx| {
            self.pos = idx;
            try self.skipLabel();
            return .normal;
        }
        return error.RuntimeError;
    }

    fn localFunctionStatement(self: *Parser) !ExecSignal {
        const name = try self.consumeIdent();
        try self.consume(.lparen);
        var params: std.ArrayList([]const u8) = .empty;
        var vararg = false;
        if (!self.match(.rparen)) {
            while (true) {
                if (self.match(.ellipsis)) {
                    vararg = true;
                    try self.consume(.rparen);
                    break;
                }
                try params.append(self.vm.allocator, try self.consumeIdent());
                if (self.match(.comma)) continue;
                try self.consume(.rparen);
                break;
            }
        }
        const body_start = self.pos;
        const body_end = try self.findEnd(body_start);
        const function = try self.vm.allocator.create(Function);
        function.* = .{
            .name = name,
            .params = try params.toOwnedSlice(self.vm.allocator),
            .vararg = vararg,
            .body_start = body_start,
            .body_end = body_end,
            .env = self.vm.captureEnvironmentForDefinition(),
            .lexical_scope_len = self.vm.scopes.items.len,
        };
        try self.vm.declare(name, .{ .function = function });
        self.pos = body_end + 1;
        return .normal;
    }

    fn returnStatement(self: *Parser) !ExecSignal {
        var values: std.ArrayList(Value) = .empty;
        if (self.peekKeyword("end") or self.peek().tag == .eof) {
            return .{ .returned = &.{} };
        }
        try self.parseExpressionList(&values);
        return .{ .returned = try values.toOwnedSlice(self.vm.allocator) };
    }

    fn doBlock(self: *Parser) !ExecSignal {
        const end_idx = try self.findEnd(self.pos);
        try self.vm.pushScope(&.{}, false);
        var body = Parser{ .vm = self.vm, .pos = self.pos, .limit = end_idx, .evaluate = self.evaluate };
        const signal = try body.parseBlock();
        self.vm.popScope();
        self.pos = end_idx + 1;
        return signal;
    }

    fn ifStatement(self: *Parser) !ExecSignal {
        const cond_start = self.pos;
        const then_idx = try self.findKeywordAtDepth(cond_start, self.limit, "then");
        const end_idx = try self.findEnd(then_idx + 1);
        const else_idx = self.findElseAtDepth(then_idx + 1, end_idx) catch end_idx;
        var cond_parser = Parser{ .vm = self.vm, .pos = cond_start, .limit = then_idx, .evaluate = self.evaluate };
        const cond = try cond_parser.expression(0);
        if (cond.isTruthy()) {
            var body = Parser{ .vm = self.vm, .pos = then_idx + 1, .limit = else_idx, .evaluate = self.evaluate };
            const signal = try body.parseBlock();
            self.pos = end_idx + 1;
            return signal;
        }
        if (else_idx != end_idx) {
            var body = Parser{ .vm = self.vm, .pos = else_idx + 1, .limit = end_idx, .evaluate = self.evaluate };
            const signal = try body.parseBlock();
            self.pos = end_idx + 1;
            return signal;
        }
        self.pos = end_idx + 1;
        return .normal;
    }

    fn whileStatement(self: *Parser) !ExecSignal {
        const cond_start = self.pos;
        const do_idx = try self.findKeywordAtDepth(cond_start, self.limit, "do");
        const body_start = do_idx + 1;
        const end_idx = try self.findEnd(body_start);
        var guard: usize = 0;
        while (true) {
            guard += 1;
            if (guard > 100000) return error.UnsupportedFeature;
            var cond_parser = Parser{ .vm = self.vm, .pos = cond_start, .limit = do_idx, .evaluate = self.evaluate };
            if (!(try cond_parser.expression(0)).isTruthy()) break;
            var body = Parser{ .vm = self.vm, .pos = body_start, .limit = end_idx, .evaluate = self.evaluate };
            const signal = try body.parseBlock();
            switch (signal) {
                .normal => {},
                .break_loop => break,
                .returned => return signal,
            }
        }
        self.pos = end_idx + 1;
        return .normal;
    }

    fn repeatStatement(self: *Parser) !ExecSignal {
        const body_start = self.pos;
        const until_idx = try self.findUntil(body_start);
        var guard: usize = 0;
        while (true) {
            guard += 1;
            if (guard > 100000) return error.UnsupportedFeature;
            var body = Parser{ .vm = self.vm, .pos = body_start, .limit = until_idx, .evaluate = self.evaluate };
            const signal = try body.parseBlock();
            switch (signal) {
                .normal => {},
                .break_loop => break,
                .returned => return signal,
            }
            var cond_parser = Parser{ .vm = self.vm, .pos = until_idx + 1, .limit = self.limit, .evaluate = self.evaluate };
            if ((try cond_parser.expression(0)).isTruthy()) break;
        }
        var tail = Parser{ .vm = self.vm, .pos = until_idx + 1, .limit = self.limit, .evaluate = self.evaluate };
        _ = try tail.expression(0);
        self.pos = tail.pos;
        return .normal;
    }

    fn forStatement(self: *Parser) !ExecSignal {
        const name = try self.consumeIdent();
        try self.consume(.assign);
        const first_comma = try self.findToken(self.pos, self.limit, .comma);
        var start_parser = Parser{ .vm = self.vm, .pos = self.pos, .limit = first_comma, .evaluate = self.evaluate };
        const start = try valueToNumber(try start_parser.expression(0));
        self.pos = first_comma + 1;
        const do_idx = try self.findKeywordAtDepth(self.pos, self.limit, "do");
        const second_comma = self.findToken(self.pos, do_idx, .comma) catch do_idx;
        var end_parser = Parser{ .vm = self.vm, .pos = self.pos, .limit = second_comma, .evaluate = self.evaluate };
        const stop = try valueToNumber(try end_parser.expression(0));
        var step: f64 = 1;
        if (second_comma != do_idx) {
            var step_parser = Parser{ .vm = self.vm, .pos = second_comma + 1, .limit = do_idx, .evaluate = self.evaluate };
            step = try valueToNumber(try step_parser.expression(0));
        }
        const body_start = do_idx + 1;
        const end_idx = try self.findEnd(body_start);
        try self.vm.pushScope(&.{}, false);
        defer self.vm.popScope();
        try self.vm.declare(name, .{ .nil = {} });
        var i = start;
        var guard: usize = 0;
        while ((step >= 0 and i <= stop) or (step < 0 and i >= stop)) : (i += step) {
            guard += 1;
            if (guard > 100000) return error.UnsupportedFeature;
            try self.vm.assignName(name, numberFromFloatIntegral(i));
            var body = Parser{ .vm = self.vm, .pos = body_start, .limit = end_idx, .evaluate = self.evaluate };
            const signal = try body.parseBlock();
            switch (signal) {
                .normal => {},
                .break_loop => break,
                .returned => return signal,
            }
        }
        self.pos = end_idx + 1;
        return .normal;
    }

    fn printStatement(self: *Parser) !ExecSignal {
        _ = try self.consumeIdent();
        try self.consume(.lparen);
        var values: std.ArrayList(Value) = .empty;
        if (!self.match(.rparen)) {
            try self.parseExpressionList(&values);
            try self.consume(.rparen);
        }
        for (values.items, 0..) |value, i| {
            if (i != 0) try self.vm.stdout.writer.writeAll("\t");
            try self.vm.writeValue(value);
        }
        try self.vm.stdout.writer.writeAll("\n");
        return .normal;
    }

    fn assignmentStatement(self: *Parser) !ExecSignal {
        var targets: std.ArrayList(AssignTarget) = .empty;
        while (true) {
            try targets.append(self.vm.allocator, try self.parseAssignTarget());
            if (!self.match(.comma)) break;
        }
        try self.consume(.assign);
        var values: std.ArrayList(Value) = .empty;
        try self.parseExpressionList(&values);
        for (targets.items, 0..) |target, i| {
            const value = if (i < values.items.len) values.items[i] else Value{ .nil = {} };
            switch (target.kind) {
                .name => try self.vm.assignName(target.name, value),
                .string_field => try target.table.?.setString(target.key_string, value),
                .index => try target.table.?.setIndex(self.vm.allocator, target.key_index, value),
            }
        }
        return .normal;
    }

    fn parseAssignTarget(self: *Parser) !AssignTarget {
        const name = try self.consumeIdent();
        if (self.match(.dot)) {
            const key = try self.consumeIdent();
            const table = switch (self.vm.lookup(name)) {
                .table => |t| t,
                else => return error.RuntimeError,
            };
            return .{ .kind = .string_field, .name = name, .table = table, .key_string = key };
        }
        if (self.match(.lbracket)) {
            const key = try self.expression(0);
            try self.consume(.rbracket);
            const table = switch (self.vm.lookup(name)) {
                .table => |t| t,
                else => return error.RuntimeError,
            };
            return .{ .kind = .index, .name = name, .table = table, .key_index = try valueToInteger(key) };
        }
        return .{ .kind = .name, .name = name };
    }

    fn parseExpressionList(self: *Parser, out: *std.ArrayList(Value)) !void {
        while (true) {
            const start = self.pos;
            const first_value = try self.expression(0);
            if (self.match(.comma)) {
                try out.append(self.vm.allocator, first_value);
                continue;
            }
            self.pos = start;
            const values = try self.expressionValues();
            try out.appendSlice(self.vm.allocator, values);
            break;
        }
    }

    fn expressionValues(self: *Parser) anyerror![]const Value {
        if (self.match(.ellipsis)) return self.vm.currentVarargs();
        if (self.peek().tag == .ident and self.peekOffset(1).tag == .lparen) {
            const callee = self.vm.lookup((try self.consumeIdent()));
            return self.callFunctionValue(callee);
        }
        const value = try self.expression(0);
        const values = try self.vm.allocator.alloc(Value, 1);
        values[0] = value;
        return values;
    }

    fn expression(self: *Parser, min_prec: u8) anyerror!Value {
        var left = try self.prefix();
        while (true) {
            const op = self.peek();
            const prec = binaryPrecedence(op);
            if (prec == 0 or prec < min_prec) break;
            _ = self.advance();
            if (op.tag == .keyword and std.mem.eql(u8, op.lexeme, "and")) {
                if (!left.isTruthy()) {
                    const previous_evaluate = self.evaluate;
                    self.evaluate = false;
                    _ = try self.expression(prec + 1);
                    self.evaluate = previous_evaluate;
                    left = left;
                } else {
                    left = try self.expression(prec + 1);
                }
                continue;
            }
            if (op.tag == .keyword and std.mem.eql(u8, op.lexeme, "or")) {
                if (left.isTruthy()) {
                    const previous_evaluate = self.evaluate;
                    self.evaluate = false;
                    _ = try self.expression(prec + 1);
                    self.evaluate = previous_evaluate;
                    left = left;
                } else {
                    left = try self.expression(prec + 1);
                }
                continue;
            }
            const right_min = if (op.tag == .concat) prec else prec + 1;
            const right = try self.expression(right_min);
            if (!self.evaluate) {
                left = .{ .nil = {} };
                continue;
            }
            left = try applyBinary(self.vm.allocator, op, left, right);
        }
        return left;
    }

    fn prefix(self: *Parser) anyerror!Value {
        if (self.match(.minus)) {
            const value = try self.expression(11);
            if (!self.evaluate) return .{ .nil = {} };
            return unaryMinus(value);
        }
        if (self.match(.len)) {
            const value = try self.expression(11);
            if (!self.evaluate) return .{ .nil = {} };
            return lengthValue(value);
        }
        if (self.match(.tilde)) {
            const value = try self.expression(11);
            if (!self.evaluate) return .{ .nil = {} };
            return bitNot(value);
        }
        if (self.matchKeyword("not")) {
            const value = try self.expression(11);
            if (!self.evaluate) return .{ .nil = {} };
            return .{ .boolean = !value.isTruthy() };
        }
        return self.postfix(try self.primary());
    }

    fn postfix(self: *Parser, initial: Value) !Value {
        var value = initial;
        while (true) {
            if (self.match(.dot)) {
                const key = try self.consumeIdent();
                value = switch (value) {
                    .table => |t| t.getString(key),
                    else => return error.RuntimeError,
                };
            } else if (self.match(.lbracket)) {
                const key = try self.expression(0);
                try self.consume(.rbracket);
                value = switch (value) {
                    .table => |t| t.getIndex(try valueToInteger(key)),
                    else => return error.RuntimeError,
                };
            } else if (self.peek().tag == .lparen) {
                if (!self.evaluate) {
                    try self.consume(.lparen);
                    if (!self.match(.rparen)) {
                        const previous_evaluate = self.evaluate;
                        self.evaluate = false;
                        var args: std.ArrayList(Value) = .empty;
                        try self.parseExpressionList(&args);
                        self.evaluate = previous_evaluate;
                        try self.consume(.rparen);
                    }
                    value = .{ .nil = {} };
                    continue;
                }
                const returns = try self.callFunctionValue(value);
                value = if (returns.len == 0) Value{ .nil = {} } else returns[0];
            } else break;
        }
        return value;
    }

    fn callFunctionValue(self: *Parser, callee: Value) anyerror![]const Value {
        try self.consume(.lparen);
        var args: std.ArrayList(Value) = .empty;
        if (!self.match(.rparen)) {
            try self.parseExpressionList(&args);
            try self.consume(.rparen);
        }
        const function = switch (callee) {
            .function => |f| f,
            .builtin => |b| return self.executeBuiltin(b, args.items),
            else => return error.RuntimeError,
        };
        return self.executeFunction(function, args.items);
    }

    fn executeBuiltin(self: *Parser, builtin: Builtin, args: []const Value) anyerror![]const Value {
        switch (builtin) {
            .print => {
                for (args, 0..) |value, i| {
                    if (i != 0) try self.vm.stdout.writer.writeAll("\t");
                    try self.vm.writeValue(value);
                }
                try self.vm.stdout.writer.writeAll("\n");
                return &.{};
            },
            .select => {
                if (args.len == 0) return error.RuntimeError;
                if (args[0] == .string and std.mem.eql(u8, args[0].string, "#")) {
                    const values = try self.vm.allocator.alloc(Value, 1);
                    values[0] = .{ .integer = @intCast(args.len - 1) };
                    return values;
                }
                const raw_index = try valueToInteger(args[0]);
                if (raw_index == 0) return error.RuntimeError;
                const payload = args[1..];
                const start: usize = if (raw_index > 0) blk: {
                    const index: usize = @intCast(raw_index - 1);
                    if (index > payload.len) break :blk payload.len;
                    break :blk index;
                } else blk: {
                    const offset: usize = @intCast(-raw_index);
                    if (offset > payload.len) return error.RuntimeError;
                    break :blk payload.len - offset;
                };
                return payload[start..];
            },
        }
    }

    fn executeFunction(self: *Parser, function: *Function, args: []const Value) anyerror![]const Value {
        const extra = if (args.len > function.params.len) args[function.params.len..] else &.{};
        try self.vm.pushScope(if (function.vararg) extra else &.{}, function.vararg);
        defer self.vm.popScope();
        try self.vm.frames.append(self.vm.allocator, .{
            .scope_start = self.vm.scopes.items.len - 1,
            .lexical_scope_len = function.lexical_scope_len,
            .env = function.env,
        });
        defer _ = self.vm.frames.pop();
        for (function.params, 0..) |param, i| {
            try self.vm.declare(param, if (i < args.len) args[i] else Value{ .nil = {} });
        }
        var body = Parser{ .vm = self.vm, .pos = function.body_start, .limit = function.body_end, .evaluate = self.evaluate };
        const signal = try body.parseBlock();
        return switch (signal) {
            .normal => &.{},
            .break_loop => error.UnsupportedFeature,
            .returned => |values| values,
        };
    }

    fn primary(self: *Parser) anyerror!Value {
        const token = self.advance();
        switch (token.tag) {
            .number => return parseNumber(token.lexeme),
            .string => return .{ .string = token.lexeme },
            .ellipsis => {
                const values = self.vm.currentVarargs();
                return if (values.len == 0) Value{ .nil = {} } else values[0];
            },
            .ident => return self.vm.lookup(token.lexeme),
            .keyword => {
                if (std.mem.eql(u8, token.lexeme, "nil")) return .{ .nil = {} };
                if (std.mem.eql(u8, token.lexeme, "true")) return .{ .boolean = true };
                if (std.mem.eql(u8, token.lexeme, "false")) return .{ .boolean = false };
                return error.UnsupportedFeature;
            },
            .lparen => {
                const value = try self.expression(0);
                try self.consume(.rparen);
                return value;
            },
            .lbrace => return self.tableConstructor(),
            else => return error.UnsupportedFeature,
        }
    }

    fn tableConstructor(self: *Parser) !Value {
        const table = try Table.create(self.vm.allocator);
        if (self.match(.rbrace)) return .{ .table = table };
        while (true) {
            if (self.peek().tag == .ident and self.peekOffset(1).tag == .assign) {
                const key = try self.consumeIdent();
                try self.consume(.assign);
                try table.setString(key, try self.expression(0));
            } else {
                const start = self.pos;
                const first_value = try self.expression(0);
                if (self.peek().tag == .comma or self.peek().tag == .semi) {
                    try table.appendArray(self.vm.allocator, first_value);
                } else {
                    self.pos = start;
                    const values = try self.expressionValues();
                    for (values) |value| try table.appendArray(self.vm.allocator, value);
                }
            }
            if (self.match(.comma) or self.match(.semi)) {
                if (self.match(.rbrace)) break;
                continue;
            }
            try self.consume(.rbrace);
            break;
        }
        return .{ .table = table };
    }

    fn findEnd(self: *Parser, start: usize) !usize {
        var depth: usize = 0;
        var i = start;
        while (i < self.limit) : (i += 1) {
            const token = self.tokens()[i];
            if (token.tag != .keyword) continue;
            if (isBlockStarter(token.lexeme, if (i > 0) self.tokens()[i - 1].lexeme else "")) {
                depth += 1;
            } else if (std.mem.eql(u8, token.lexeme, "until")) {
                if (depth > 0) depth -= 1;
            } else if (std.mem.eql(u8, token.lexeme, "end")) {
                if (depth == 0) return i;
                depth -= 1;
            }
        }
        return error.SyntaxError;
    }

    fn findUntil(self: *Parser, start: usize) !usize {
        var depth: usize = 0;
        var i = start;
        while (i < self.limit) : (i += 1) {
            const token = self.tokens()[i];
            if (token.tag != .keyword) continue;
            if (isBlockStarter(token.lexeme, if (i > 0) self.tokens()[i - 1].lexeme else "")) depth += 1 else if (std.mem.eql(u8, token.lexeme, "end")) {
                if (depth > 0) depth -= 1;
            } else if (std.mem.eql(u8, token.lexeme, "until")) {
                if (depth == 0) return i;
                depth -= 1;
            }
        }
        return error.UnsupportedFeature;
    }

    fn findKeywordAtDepth(self: *Parser, start: usize, end: usize, keyword: []const u8) !usize {
        var i = start;
        while (i < end) : (i += 1) {
            if (self.tokens()[i].tag == .keyword and std.mem.eql(u8, self.tokens()[i].lexeme, keyword)) return i;
        }
        return error.UnsupportedFeature;
    }

    fn findElseAtDepth(self: *Parser, start: usize, end: usize) !usize {
        var depth: usize = 0;
        var i = start;
        while (i < end) : (i += 1) {
            const token = self.tokens()[i];
            if (token.tag != .keyword) continue;
            if (depth == 0 and std.mem.eql(u8, token.lexeme, "else")) return i;
            if (isBlockStarter(token.lexeme, if (i > 0) self.tokens()[i - 1].lexeme else "")) {
                depth += 1;
            } else if (std.mem.eql(u8, token.lexeme, "until") or std.mem.eql(u8, token.lexeme, "end")) {
                if (depth > 0) depth -= 1;
            }
        }
        return error.UnsupportedFeature;
    }

    fn findToken(self: *Parser, start: usize, end: usize, tag: TokenTag) !usize {
        var i = start;
        while (i < end) : (i += 1) {
            if (self.tokens()[i].tag == tag) return i;
        }
        return error.UnsupportedFeature;
    }

    fn findLabel(self: *Parser, start: usize, end: usize, label: []const u8) ?usize {
        var i = start;
        while (i + 2 < end) : (i += 1) {
            if (self.tokens()[i].tag == .coloncolon and
                self.tokens()[i + 1].tag == .ident and
                std.mem.eql(u8, self.tokens()[i + 1].lexeme, label) and
                self.tokens()[i + 2].tag == .coloncolon)
            {
                return i;
            }
        }
        return null;
    }

    fn tokens(self: *Parser) []const Token {
        return self.vm.tokens;
    }
    fn peek(self: *Parser) Token {
        return self.peekOffset(0);
    }
    fn peekOffset(self: *Parser, offset: usize) Token {
        const idx = self.pos + offset;
        if (idx >= self.limit) return .{ .tag = .eof, .lexeme = "", .line = if (self.limit == 0) 1 else self.tokens()[@min(self.limit - 1, self.tokens().len - 1)].line };
        return self.tokens()[idx];
    }
    fn advance(self: *Parser) Token {
        const token = self.peek();
        if (self.pos < self.limit) self.pos += 1;
        return token;
    }
    fn match(self: *Parser, tag: TokenTag) bool {
        if (self.peek().tag == tag) {
            _ = self.advance();
            return true;
        }
        return false;
    }
    fn consume(self: *Parser, tag: TokenTag) !void {
        if (!self.match(tag)) return error.UnsupportedFeature;
    }
    fn consumeIdent(self: *Parser) ![]const u8 {
        if (self.peek().tag != .ident) return error.UnsupportedFeature;
        return self.advance().lexeme;
    }
    fn matchKeyword(self: *Parser, word: []const u8) bool {
        if (self.peekKeyword(word)) {
            _ = self.advance();
            return true;
        }
        return false;
    }
    fn peekKeyword(self: *Parser, word: []const u8) bool {
        const t = self.peek();
        return t.tag == .keyword and std.mem.eql(u8, t.lexeme, word);
    }
    fn peekIdent(self: *Parser, word: []const u8) bool {
        const t = self.peek();
        return t.tag == .ident and std.mem.eql(u8, t.lexeme, word);
    }
};

pub fn runLevel0(allocator: std.mem.Allocator, source: []const u8) !VmResult {
    return runLevel0WithArgStrings(allocator, source, &.{});
}

pub fn runLevel0WithArgStrings(
    allocator: std.mem.Allocator,
    source: []const u8,
    args: []const []const u8,
) !VmResult {
    var tokens = lex(allocator, source) catch |err| switch (err) {
        error.UnsupportedFeature => return unsupported(allocator, "lexer"),
        else => return err,
    };
    const eof_line = sourceEofLine(source);
    try tokens.append(allocator, .{ .tag = .eof, .lexeme = "", .line = eof_line });
    const token_slice = try tokens.toOwnedSlice(allocator);
    if (try validateGotoAndLabels(allocator, token_slice)) |diagnostic| {
        return syntaxErrorAt(allocator, diagnostic.line, diagnostic.message);
    }
    if (classifyUnsupportedTokens(token_slice)) |reason| {
        return unsupported(allocator, reason);
    }
    var varargs: std.ArrayList(Value) = .empty;
    for (args) |arg| try varargs.append(allocator, .{ .string = arg });
    var vm = try Vm.initWithVarargs(allocator, token_slice, try varargs.toOwnedSlice(allocator));
    var parser = Parser{ .vm = &vm, .pos = 0, .limit = token_slice.len, .evaluate = true };
    _ = parser.parseBlock() catch |err| switch (err) {
        error.RuntimeError => return runtimeError(allocator, "attempt to perform arithmetic on an unsupported value"),
        error.SyntaxError => return syntaxError(allocator, "end-expected"),
        error.UnsupportedFeature => return unsupported(allocator, "outside-level0-subset"),
        else => return err,
    };
    return .{ .state = .pass, .stdout = try vm.stdout.toOwnedSlice(), .stderr = "", .exit_code = 0, .unsupported_reason = null };
}

fn sourceEofLine(source: []const u8) usize {
    var line: usize = 1;
    for (source) |byte| {
        if (byte == '\n') line += 1;
    }
    return line;
}

const GotoDiagnostic = struct {
    line: usize,
    message: []const u8,
};

const LabelInfo = struct {
    name: []const u8,
    line: usize,
    index: usize,
    block_id: usize,
};

const GotoInfo = struct {
    name: []const u8,
    line: usize,
    index: usize,
    block_id: usize,
    block_path: []const usize,
};

const LocalInfo = struct {
    name: []const u8,
    index: usize,
    block_id: usize,
};

fn validateGotoAndLabels(allocator: std.mem.Allocator, tokens: []const Token) !?GotoDiagnostic {
    var labels: std.ArrayList(LabelInfo) = .empty;
    var gotos: std.ArrayList(GotoInfo) = .empty;
    var locals: std.ArrayList(LocalInfo) = .empty;
    var block_stack: std.ArrayList(usize) = .empty;
    try block_stack.append(allocator, 0);
    var next_block_id: usize = 1;

    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const token = tokens[i];
        if (token.tag == .eof) break;

        if (token.tag == .coloncolon) {
            if (i + 1 >= tokens.len or tokens[i + 1].tag != .ident) {
                return .{ .line = token.line, .message = try std.fmt.allocPrint(allocator, "<name> expected near {s}", .{try tokenNearText(allocator, if (i + 1 < tokens.len) tokens[i + 1] else token)}) };
            }
            if (i + 2 >= tokens.len or tokens[i + 2].tag != .coloncolon) {
                return .{ .line = if (i + 2 < tokens.len) tokens[i + 2].line else token.line + 1, .message = try std.fmt.allocPrint(allocator, "'::' expected near {s}", .{try tokenNearText(allocator, if (i + 2 < tokens.len) tokens[i + 2] else Token{ .tag = .eof, .lexeme = "", .line = token.line })}) };
            }
            const label = tokens[i + 1];
            const block_id = block_stack.items[block_stack.items.len - 1];
            for (labels.items) |existing| {
                if (existing.block_id == block_id and std.mem.eql(u8, existing.name, label.lexeme)) {
                    return .{ .line = label.line, .message = try std.fmt.allocPrint(allocator, "label '{s}' already defined on line {d}", .{ label.lexeme, label.line }) };
                }
            }
            try labels.append(allocator, .{ .name = label.lexeme, .line = label.line, .index = i, .block_id = block_id });
            i += 2;
            continue;
        }

        if (token.tag == .keyword and std.mem.eql(u8, token.lexeme, "goto")) {
            if (i + 1 >= tokens.len or tokens[i + 1].tag != .ident) {
                return .{ .line = token.line, .message = try std.fmt.allocPrint(allocator, "<name> expected near {s}", .{try tokenNearText(allocator, if (i + 1 < tokens.len) tokens[i + 1] else token)}) };
            }
            try gotos.append(allocator, .{
                .name = tokens[i + 1].lexeme,
                .line = token.line,
                .index = i,
                .block_id = block_stack.items[block_stack.items.len - 1],
                .block_path = try allocator.dupe(usize, block_stack.items),
            });
            i += 1;
            continue;
        }

        if (token.tag == .keyword and std.mem.eql(u8, token.lexeme, "local")) {
            try collectLocalNames(allocator, tokens, i, block_stack.items[block_stack.items.len - 1], &locals);
        }

        if (token.tag == .keyword) {
            if (std.mem.eql(u8, token.lexeme, "end") or std.mem.eql(u8, token.lexeme, "until")) {
                if (block_stack.items.len > 1) _ = block_stack.pop();
            } else if (std.mem.eql(u8, token.lexeme, "else")) {
                if (block_stack.items.len > 1) _ = block_stack.pop();
                try block_stack.append(allocator, next_block_id);
                next_block_id += 1;
            } else if (std.mem.eql(u8, token.lexeme, "then") or
                std.mem.eql(u8, token.lexeme, "do") or
                std.mem.eql(u8, token.lexeme, "repeat") or
                std.mem.eql(u8, token.lexeme, "function"))
            {
                try block_stack.append(allocator, next_block_id);
                next_block_id += 1;
            }
        }
    }

    for (gotos.items) |goto_ref| {
        const label = findVisibleLabel(labels.items, goto_ref) orelse {
            return .{ .line = goto_ref.line, .message = try std.fmt.allocPrint(allocator, "no visible label '{s}' for <goto> at line {d}", .{ goto_ref.name, goto_ref.line }) };
        };
        if (label.block_id == goto_ref.block_id and goto_ref.index < label.index) {
            for (locals.items) |local_info| {
                if (local_info.block_id == goto_ref.block_id and goto_ref.index < local_info.index and local_info.index < label.index) {
                    return .{ .line = label.line + 1, .message = try std.fmt.allocPrint(allocator, "<goto {s}> at line {d} jumps into the scope of '{s}'", .{ goto_ref.name, goto_ref.line, local_info.name }) };
                }
            }
        }
    }

    return null;
}

fn collectLocalNames(
    allocator: std.mem.Allocator,
    tokens: []const Token,
    local_index: usize,
    block_id: usize,
    locals: *std.ArrayList(LocalInfo),
) !void {
    var p = local_index + 1;
    if (p < tokens.len and tokens[p].tag == .keyword and std.mem.eql(u8, tokens[p].lexeme, "function")) {
        p += 1;
        if (p < tokens.len and tokens[p].tag == .ident) {
            try locals.append(allocator, .{ .name = tokens[p].lexeme, .index = local_index, .block_id = block_id });
        }
        return;
    }
    while (p < tokens.len) {
        if (tokens[p].tag != .ident) break;
        try locals.append(allocator, .{ .name = tokens[p].lexeme, .index = local_index, .block_id = block_id });
        p += 1;
        if (p >= tokens.len or tokens[p].tag != .comma) break;
        p += 1;
    }
}

fn findVisibleLabel(labels: []const LabelInfo, goto_ref: GotoInfo) ?LabelInfo {
    var best: ?LabelInfo = null;
    var best_depth: usize = 0;
    for (labels) |label| {
        if (!std.mem.eql(u8, label.name, goto_ref.name)) continue;
        if (blockDepthInPath(goto_ref.block_path, label.block_id)) |depth| {
            if (best == null or depth >= best_depth) {
                best = label;
                best_depth = depth;
            }
        }
    }
    return best;
}

fn blockDepthInPath(path: []const usize, block_id: usize) ?usize {
    for (path, 0..) |id, depth| {
        if (id == block_id) return depth;
    }
    return null;
}

fn tokenNearText(allocator: std.mem.Allocator, token: Token) ![]const u8 {
    if (token.tag == .eof) return "<eof>";
    return try std.fmt.allocPrint(allocator, "'{s}'", .{token.lexeme});
}

fn classifyUnsupportedTokens(tokens: []const Token) ?[]const u8 {
    if (detectNamedClosureEscape(tokens)) return "closure-upvalues";
    if (classifyAdvancedHookBoundary(tokens)) |boundary| return advanced_hooks.reasonName(boundary);
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const token = tokens[i];
        if (token.tag == .keyword and std.mem.eql(u8, token.lexeme, "return")) {
            if (i + 1 < tokens.len and tokens[i + 1].tag == .keyword and std.mem.eql(u8, tokens[i + 1].lexeme, "function")) return "closure-upvalues";
        }
        if (token.tag == .keyword and std.mem.eql(u8, token.lexeme, "function")) {
            if (i + 1 < tokens.len and tokens[i + 1].tag == .lparen) return "closure-upvalues";
        }
        if (token.tag == .ident and std.mem.eql(u8, token.lexeme, "_ENV")) {
            if (i + 1 < tokens.len and tokens[i + 1].tag == .lbracket) return "dynamic-env-mutation";
            if (i + 1 < tokens.len and tokens[i + 1].tag == .assign) {
                const is_local_declaration = i > 0 and tokens[i - 1].tag == .keyword and std.mem.eql(u8, tokens[i - 1].lexeme, "local");
                if (!is_local_declaration) return "dynamic-env-mutation";
            }
        }
        if (token.tag == .ident) {
            if (std.mem.eql(u8, token.lexeme, "load")) return "load";
            if (std.mem.eql(u8, token.lexeme, "debug")) return "debug";
            if (std.mem.eql(u8, token.lexeme, "assert")) return "puc-test-harness";
        }
    }
    return null;
}

const AdvancedScanState = struct {
    saw_metatable: bool = false,
    saw_protected: bool = false,
    saw_binary_dump: bool = false,

    fn observeIdent(
        self: *AdvancedScanState,
        tokens: []const Token,
        i: usize,
        bindings: []const ClosureBinding,
    ) ?advanced_hooks.HookBoundary {
        const token = tokens[i];
        if (token.tag != .ident) return null;
        if (isFieldName(tokens, i) or isTableConstructorKey(tokens, i)) return null;
        if (hasActiveBinding(bindings, token.lexeme)) return null;

        if (std.mem.eql(u8, token.lexeme, "rawget") or
            std.mem.eql(u8, token.lexeme, "rawset") or
            std.mem.eql(u8, token.lexeme, "rawequal") or
            std.mem.eql(u8, token.lexeme, "rawlen"))
        {
            return .raw_ops;
        }
        if (std.mem.eql(u8, token.lexeme, "collectgarbage")) return .gc_weak_finalization;
        if (std.mem.eql(u8, token.lexeme, "coroutine")) return .coroutine_model;
        if (std.mem.eql(u8, token.lexeme, "pairs") or
            std.mem.eql(u8, token.lexeme, "ipairs") or
            std.mem.eql(u8, token.lexeme, "next"))
        {
            return .table_iteration;
        }
        if (std.mem.eql(u8, token.lexeme, "close")) {
            const attr_left = i > 0 and tokens[i - 1].tag == .lt;
            const attr_right = i + 1 < tokens.len and tokens[i + 1].tag == .gt;
            if (attr_left and attr_right) return .cleanup_finalization;
        }
        if (std.mem.eql(u8, token.lexeme, "string") and i + 2 < tokens.len and
            tokens[i + 1].tag == .dot and tokens[i + 2].tag == .ident and
            std.mem.eql(u8, tokens[i + 2].lexeme, "dump"))
        {
            self.saw_binary_dump = true;
        }
        if (std.mem.eql(u8, token.lexeme, "load") and self.saw_binary_dump) return .binary_dynamic_gates;
        if (std.mem.eql(u8, token.lexeme, "pcall") or
            std.mem.eql(u8, token.lexeme, "xpcall") or
            std.mem.eql(u8, token.lexeme, "error"))
        {
            self.saw_protected = true;
        }
        if (std.mem.eql(u8, token.lexeme, "setmetatable")) self.saw_metatable = true;
        return null;
    }

    fn finish(self: AdvancedScanState) ?advanced_hooks.HookBoundary {
        if (self.saw_metatable and self.saw_protected) return .cross_boundary_advanced;
        if (self.saw_binary_dump) return .binary_dynamic_gates;
        if (self.saw_protected) return .protected_error;
        if (self.saw_metatable) return .metatable_dispatch;
        return null;
    }
};

fn classifyAdvancedHookBoundary(tokens: []const Token) ?advanced_hooks.HookBoundary {
    var bindings: [128]ClosureBinding = undefined;
    var binding_count: usize = 0;
    var depth: usize = 0;
    var state = AdvancedScanState{};
    var pending_until_prune_at: ?usize = null;
    var pending_until_prune_depth: usize = 0;

    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        if (pending_until_prune_at) |prune_at| {
            if (i >= prune_at) {
                depth = pending_until_prune_depth;
                pruneBindings(&bindings, &binding_count, depth);
                pending_until_prune_at = null;
            }
        }

        const token = tokens[i];
        if (isBranchBoundaryToken(token)) {
            pruneBindings(&bindings, &binding_count, if (depth > 0) depth - 1 else 0);
        }

        if (token.tag == .keyword and std.mem.eql(u8, token.lexeme, "end")) {
            if (depth > 0) {
                depth -= 1;
                pruneBindings(&bindings, &binding_count, depth);
            }
            continue;
        }
        if (token.tag == .keyword and std.mem.eql(u8, token.lexeme, "until")) {
            if (depth > 0) {
                const pruned_depth = depth - 1;
                const condition_end = findUntilConditionEnd(tokens, i + 1);
                if (condition_end <= i + 1) {
                    depth = pruned_depth;
                    pruneBindings(&bindings, &binding_count, depth);
                } else {
                    pending_until_prune_depth = pruned_depth;
                    pending_until_prune_at = condition_end;
                }
            }
            continue;
        }

        if (token.tag == .keyword and std.mem.eql(u8, token.lexeme, "local")) {
            if (classifyLocalInitializerAdvanced(tokens, i, bindings[0..binding_count], &state)) |boundary| return boundary;
            addLocalBindings(tokens, i, depth, &bindings, &binding_count);
        } else if (token.tag == .keyword and std.mem.eql(u8, token.lexeme, "function")) {
            addFunctionParamBindings(tokens, i, depth + 1, &bindings, &binding_count);
        } else if (token.tag == .keyword and std.mem.eql(u8, token.lexeme, "for")) {
            if (i + 1 < tokens.len and tokens[i + 1].tag == .ident and i + 2 < tokens.len and tokens[i + 2].tag == .assign) {
                addAdvancedBinding(&bindings, &binding_count, tokens[i + 1].lexeme, depth + 1);
            }
        } else if (state.observeIdent(tokens, i, bindings[0..binding_count])) |boundary| {
            return boundary;
        }

        if (token.tag == .keyword and isBlockStarter(token.lexeme, if (i > 0) tokens[i - 1].lexeme else "")) depth += 1;
    }

    return state.finish();
}

const ClosureBinding = struct {
    name: []const u8,
    depth: usize,
};

const AssignmentTargetKind = enum { plain_name, field_or_index };

const AssignmentTargetInfo = struct {
    kind: AssignmentTargetKind,
    name: []const u8,
};

const IdentifierExpression = struct {
    name: []const u8,
    next: usize,
};

fn hasBinding(bindings: []const ClosureBinding, name: []const u8, depth: usize) bool {
    for (bindings) |binding| {
        if (binding.depth == depth and std.mem.eql(u8, binding.name, name)) return true;
    }
    return false;
}

fn addBinding(bindings: *[64]ClosureBinding, count: *usize, name: []const u8, depth: usize) void {
    if (count.* >= bindings.len) return;
    if (hasBinding(bindings[0..count.*], name, depth)) return;
    bindings[count.*] = .{ .name = name, .depth = depth };
    count.* += 1;
}

fn addAdvancedBinding(bindings: *[128]ClosureBinding, count: *usize, name: []const u8, depth: usize) void {
    if (count.* >= bindings.len) return;
    if (hasBinding(bindings[0..count.*], name, depth)) return;
    bindings[count.*] = .{ .name = name, .depth = depth };
    count.* += 1;
}

fn hasActiveBinding(bindings: []const ClosureBinding, name: []const u8) bool {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.name, name)) return true;
    }
    return false;
}

fn pruneBindings(bindings: *[128]ClosureBinding, count: *usize, max_depth: usize) void {
    var write: usize = 0;
    var read: usize = 0;
    while (read < count.*) : (read += 1) {
        if (bindings[read].depth <= max_depth) {
            bindings[write] = bindings[read];
            write += 1;
        }
    }
    count.* = write;
}

fn isFieldName(tokens: []const Token, i: usize) bool {
    return i > 0 and tokens[i - 1].tag == .dot;
}

fn isTableConstructorKey(tokens: []const Token, i: usize) bool {
    if (i + 1 >= tokens.len or tokens[i + 1].tag != .assign) return false;
    if (i == 0) return false;
    return tokens[i - 1].tag == .lbrace or tokens[i - 1].tag == .comma;
}

fn isBranchBoundaryToken(token: Token) bool {
    return (token.tag == .keyword or token.tag == .ident) and
        (std.mem.eql(u8, token.lexeme, "else") or std.mem.eql(u8, token.lexeme, "elseif"));
}

fn addLocalBindings(tokens: []const Token, local_index: usize, depth: usize, bindings: *[128]ClosureBinding, count: *usize) void {
    if (local_index + 1 >= tokens.len) return;
    if (tokens[local_index + 1].tag == .keyword and std.mem.eql(u8, tokens[local_index + 1].lexeme, "function")) {
        if (local_index + 2 < tokens.len and tokens[local_index + 2].tag == .ident) {
            addAdvancedBinding(bindings, count, tokens[local_index + 2].lexeme, depth);
        }
        addFunctionParamBindings(tokens, local_index + 1, depth + 1, bindings, count);
        return;
    }

    var p = local_index + 1;
    while (p < tokens.len and tokens[p].tag == .ident) {
        addAdvancedBinding(bindings, count, tokens[p].lexeme, depth);
        p += 1;
        if (p < tokens.len and tokens[p].tag == .comma) {
            p += 1;
            continue;
        }
        break;
    }
}

fn addFunctionParamBindings(tokens: []const Token, function_index: usize, depth: usize, bindings: *[128]ClosureBinding, count: *usize) void {
    var p = function_index + 1;
    while (p < tokens.len and tokens[p].tag != .lparen and tokens[p].tag != .eof) : (p += 1) {}
    if (p >= tokens.len or tokens[p].tag != .lparen) return;
    p += 1;
    while (p < tokens.len and tokens[p].tag != .rparen and tokens[p].tag != .eof) : (p += 1) {
        if (tokens[p].tag == .ident) addAdvancedBinding(bindings, count, tokens[p].lexeme, depth);
    }
}

fn classifyLocalInitializerAdvanced(
    tokens: []const Token,
    local_index: usize,
    bindings: []const ClosureBinding,
    state: *AdvancedScanState,
) ?advanced_hooks.HookBoundary {
    if (local_index + 1 >= tokens.len) return null;
    if (tokens[local_index + 1].tag == .keyword and std.mem.eql(u8, tokens[local_index + 1].lexeme, "function")) return null;
    var p = local_index + 1;
    while (p < tokens.len and tokens[p].tag == .ident) {
        p += 1;
        if (p < tokens.len and tokens[p].tag == .comma) {
            p += 1;
            continue;
        }
        break;
    }
    if (p >= tokens.len or tokens[p].tag != .assign) return null;
    p += 1;
    while (p < tokens.len) {
        const end = skipExpression(tokens, p, true);
        if (classifyAdvancedRange(tokens, p, end, bindings, state)) |boundary| return boundary;
        p = end;
        if (p < tokens.len and tokens[p].tag == .comma) {
            p += 1;
            continue;
        }
        break;
    }
    return null;
}

fn classifyAdvancedRange(
    tokens: []const Token,
    start: usize,
    end: usize,
    bindings: []const ClosureBinding,
    state: *AdvancedScanState,
) ?advanced_hooks.HookBoundary {
    var i = start;
    while (i < end and i < tokens.len) : (i += 1) {
        if (state.observeIdent(tokens, i, bindings)) |boundary| return boundary;
    }
    return null;
}

fn isClosureBindingAtDepth(
    nested_functions: []const ClosureBinding,
    closure_aliases: []const ClosureBinding,
    name: []const u8,
    depth: usize,
) bool {
    return hasBinding(nested_functions, name, depth) or hasBinding(closure_aliases, name, depth);
}

fn parseIdentifierExpression(tokens: []const Token, start: usize) ?IdentifierExpression {
    if (start >= tokens.len) return null;
    if (tokens[start].tag == .ident) return .{ .name = tokens[start].lexeme, .next = start + 1 };
    if (tokens[start].tag != .lparen) return null;
    const inner = parseIdentifierExpression(tokens, start + 1) orelse return null;
    if (inner.next >= tokens.len or tokens[inner.next].tag != .rparen) return null;
    return .{ .name = inner.name, .next = inner.next + 1 };
}

fn normalizedIdentifierExpression(tokens: []const Token, start: usize) ?IdentifierExpression {
    const parsed = parseIdentifierExpression(tokens, start) orelse return null;
    if (parsed.next < tokens.len) {
        switch (tokens[parsed.next].tag) {
            .lparen, .dot, .lbracket => return null,
            else => {},
        }
    }
    return parsed;
}

fn skipBalanced(tokens: []const Token, start: usize, open: TokenTag, close: TokenTag) usize {
    var depth: usize = 1;
    var i = start + 1;
    while (i < tokens.len) : (i += 1) {
        if (tokens[i].tag == open) {
            depth += 1;
        } else if (tokens[i].tag == close) {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return i;
}

fn skipExpression(tokens: []const Token, start: usize, stop_after_single_expression: bool) usize {
    var i = start;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const token = tokens[i];
        if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
            if (token.tag == .comma) return i;
            if (token.tag == .eof) return i;
            if (token.tag == .keyword and (std.mem.eql(u8, token.lexeme, "end") or
                std.mem.eql(u8, token.lexeme, "else") or
                std.mem.eql(u8, token.lexeme, "until") or
                std.mem.eql(u8, token.lexeme, "return") or
                std.mem.eql(u8, token.lexeme, "local"))) return i;
            if (stop_after_single_expression and i > start) return i;
        }
        switch (token.tag) {
            .lparen => paren_depth += 1,
            .rparen => {
                if (paren_depth > 0) paren_depth -= 1 else return i;
            },
            .lbracket => bracket_depth += 1,
            .rbracket => {
                if (bracket_depth > 0) bracket_depth -= 1 else return i;
            },
            .lbrace => brace_depth += 1,
            .rbrace => {
                if (brace_depth > 0) brace_depth -= 1 else return i;
            },
            else => {},
        }
    }
    return i;
}

fn findUntilConditionEnd(tokens: []const Token, start: usize) usize {
    var i = start;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var previous: ?Token = null;
    var saw_expression_token = false;
    while (i < tokens.len) : (i += 1) {
        const token = tokens[i];
        const top_level = paren_depth == 0 and bracket_depth == 0 and brace_depth == 0;
        if (top_level and saw_expression_token) {
            if (isStatementBoundaryKeyword(token)) return i;
            if (previous) |prev| {
                if (canEndExpression(prev) and canStartExpression(token) and !isPostfixContinuation(token)) return i;
            }
        }

        switch (token.tag) {
            .lparen => paren_depth += 1,
            .rparen => {
                if (paren_depth > 0) paren_depth -= 1 else return i;
            },
            .lbracket => bracket_depth += 1,
            .rbracket => {
                if (bracket_depth > 0) bracket_depth -= 1 else return i;
            },
            .lbrace => brace_depth += 1,
            .rbrace => {
                if (brace_depth > 0) brace_depth -= 1 else return i;
            },
            .comma, .eof => if (top_level) return i,
            else => {},
        }
        saw_expression_token = true;
        previous = token;
    }
    return i;
}

fn isStatementBoundaryKeyword(token: Token) bool {
    if (token.tag != .keyword) return false;
    return std.mem.eql(u8, token.lexeme, "local") or
        std.mem.eql(u8, token.lexeme, "return") or
        std.mem.eql(u8, token.lexeme, "break") or
        std.mem.eql(u8, token.lexeme, "if") or
        std.mem.eql(u8, token.lexeme, "for") or
        std.mem.eql(u8, token.lexeme, "while") or
        std.mem.eql(u8, token.lexeme, "repeat") or
        std.mem.eql(u8, token.lexeme, "function") or
        std.mem.eql(u8, token.lexeme, "do") or
        std.mem.eql(u8, token.lexeme, "end") or
        std.mem.eql(u8, token.lexeme, "else") or
        std.mem.eql(u8, token.lexeme, "until");
}

fn canEndExpression(token: Token) bool {
    return switch (token.tag) {
        .ident, .number, .string, .rparen, .rbrace, .rbracket, .ellipsis => true,
        .keyword => std.mem.eql(u8, token.lexeme, "nil") or
            std.mem.eql(u8, token.lexeme, "true") or
            std.mem.eql(u8, token.lexeme, "false"),
        else => false,
    };
}

fn canStartExpression(token: Token) bool {
    return switch (token.tag) {
        .ident, .number, .string, .lparen, .lbrace, .minus, .len, .tilde, .ellipsis => true,
        .keyword => std.mem.eql(u8, token.lexeme, "nil") or
            std.mem.eql(u8, token.lexeme, "true") or
            std.mem.eql(u8, token.lexeme, "false") or
            std.mem.eql(u8, token.lexeme, "not"),
        else => false,
    };
}

fn isPostfixContinuation(token: Token) bool {
    return token.tag == .lparen or token.tag == .dot or token.tag == .lbracket;
}

fn parseAssignmentTarget(tokens: []const Token, start: usize) ?struct { target: AssignmentTargetInfo, next: usize } {
    if (start >= tokens.len or tokens[start].tag != .ident) return null;
    var target = AssignmentTargetInfo{ .kind = .plain_name, .name = tokens[start].lexeme };
    var p = start + 1;
    while (p < tokens.len) {
        if (tokens[p].tag == .dot) {
            if (p + 1 >= tokens.len or tokens[p + 1].tag != .ident) return null;
            target.kind = .field_or_index;
            p += 2;
            continue;
        }
        if (tokens[p].tag == .lbracket) {
            target.kind = .field_or_index;
            p = skipBalanced(tokens, p, .lbracket, .rbracket);
            continue;
        }
        break;
    }
    return .{ .target = target, .next = p };
}

fn detectNamedClosureEscape(tokens: []const Token) bool {
    var nested_functions: [64]ClosureBinding = undefined;
    var closure_aliases: [64]ClosureBinding = undefined;
    var local_names: [64]ClosureBinding = undefined;
    var nested_count: usize = 0;
    var alias_count: usize = 0;
    var local_count: usize = 0;
    var depth: usize = 0;
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const token = tokens[i];
        if (token.tag == .keyword and std.mem.eql(u8, token.lexeme, "local")) {
            if (i + 2 < tokens.len and tokens[i + 1].tag == .keyword and std.mem.eql(u8, tokens[i + 1].lexeme, "function") and tokens[i + 2].tag == .ident and depth > 0 and nested_count < nested_functions.len) {
                addBinding(&local_names, &local_count, tokens[i + 2].lexeme, depth);
                addBinding(&nested_functions, &nested_count, tokens[i + 2].lexeme, depth);
            }
            if (i + 1 < tokens.len and tokens[i + 1].tag == .ident) {
                var names: [16][]const u8 = undefined;
                var name_count: usize = 0;
                var p = i + 1;
                while (p < tokens.len and name_count < names.len and tokens[p].tag == .ident) {
                    names[name_count] = tokens[p].lexeme;
                    name_count += 1;
                    addBinding(&local_names, &local_count, tokens[p].lexeme, depth);
                    p += 1;
                    if (p < tokens.len and tokens[p].tag == .comma) {
                        p += 1;
                        continue;
                    }
                    break;
                }
                if (p < tokens.len and tokens[p].tag == .assign) {
                    p += 1;
                    var value_index: usize = 0;
                    while (p < tokens.len and value_index < name_count) : (value_index += 1) {
                        if (normalizedIdentifierExpression(tokens, p)) |expr| {
                            if (isClosureBindingAtDepth(nested_functions[0..nested_count], closure_aliases[0..alias_count], expr.name, depth)) {
                                addBinding(&closure_aliases, &alias_count, names[value_index], depth);
                            }
                        }
                        p = skipExpression(tokens, p, value_index + 1 >= name_count);
                        if (p < tokens.len and tokens[p].tag == .comma) {
                            p += 1;
                        } else break;
                    }
                }
            }
        } else if (token.tag == .ident and (i == 0 or tokens[i - 1].tag != .dot)) {
            var targets: [16]AssignmentTargetInfo = undefined;
            var target_count: usize = 0;
            var p = i;
            while (target_count < targets.len) {
                const parsed = parseAssignmentTarget(tokens, p) orelse break;
                targets[target_count] = parsed.target;
                target_count += 1;
                p = parsed.next;
                if (p < tokens.len and tokens[p].tag == .comma) {
                    p += 1;
                    continue;
                }
                break;
            }
            if (target_count > 0 and p < tokens.len and tokens[p].tag == .assign) {
                p += 1;
                var value_index: usize = 0;
                while (p < tokens.len and value_index < target_count) : (value_index += 1) {
                    if (normalizedIdentifierExpression(tokens, p)) |expr| {
                        if (isClosureBindingAtDepth(nested_functions[0..nested_count], closure_aliases[0..alias_count], expr.name, depth)) {
                            const target = targets[value_index];
                            if (target.kind == .field_or_index or !hasBinding(local_names[0..local_count], target.name, depth)) return true;
                            addBinding(&closure_aliases, &alias_count, target.name, depth);
                        }
                    }
                    p = skipExpression(tokens, p, value_index + 1 >= target_count);
                    if (p < tokens.len and tokens[p].tag == .comma) {
                        p += 1;
                    } else break;
                }
            }
        }
        if (token.tag == .keyword and std.mem.eql(u8, token.lexeme, "return")) {
            var p = i + 1;
            while (p < tokens.len) {
                if (normalizedIdentifierExpression(tokens, p)) |expr| {
                    if (isClosureBindingAtDepth(nested_functions[0..nested_count], closure_aliases[0..alias_count], expr.name, depth)) return true;
                }
                p = skipExpression(tokens, p, false);
                if (p < tokens.len and tokens[p].tag == .comma) {
                    p += 1;
                    continue;
                }
                break;
            }
        }
        if (token.tag != .keyword) continue;
        if (std.mem.eql(u8, token.lexeme, "end") or std.mem.eql(u8, token.lexeme, "until")) {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (isBlockStarter(token.lexeme, if (i > 0) tokens[i - 1].lexeme else "")) depth += 1;
    }
    return false;
}

fn unsupported(allocator: std.mem.Allocator, reason: []const u8) !VmResult {
    return .{ .state = .unsupported, .stdout = "", .stderr = try std.fmt.allocPrint(allocator, "ziglua-vm: unsupported/fallback Level 1 snippet: {s}\n", .{reason}), .exit_code = 1, .unsupported_reason = reason };
}

fn runtimeError(allocator: std.mem.Allocator, message: []const u8) !VmResult {
    return .{ .state = .runtime_error, .stdout = "", .stderr = try std.fmt.allocPrint(allocator, "ziglua-vm: {s}\n", .{message}), .exit_code = 1, .unsupported_reason = null };
}

fn syntaxError(allocator: std.mem.Allocator, reason: []const u8) !VmResult {
    return .{ .state = .runtime_error, .stdout = "", .stderr = try std.fmt.allocPrint(allocator, "ziglua-vm: syntax-error:{s}\n", .{reason}), .exit_code = 1, .unsupported_reason = null };
}

fn syntaxErrorAt(allocator: std.mem.Allocator, line: usize, message: []const u8) !VmResult {
    return .{ .state = .runtime_error, .stdout = "", .stderr = try std.fmt.allocPrint(allocator, "ziglua-vm: syntax-error:{d}:{s}\n", .{ line, message }), .exit_code = 1, .unsupported_reason = null };
}

fn lex(allocator: std.mem.Allocator, source: []const u8) !std.ArrayList(Token) {
    var tokens: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    var line: usize = 1;
    while (i < source.len) {
        const c = source[i];
        if (std.ascii.isWhitespace(c)) {
            if (c == '\n') line += 1;
            i += 1;
            continue;
        }
        if (c == '-' and i + 1 < source.len and source[i + 1] == '-') {
            i += 2;
            if (i + 1 < source.len and source[i] == '[' and source[i + 1] == '[') {
                i += 2;
                while (i + 1 < source.len and !(source[i] == ']' and source[i + 1] == ']')) : (i += 1) {
                    if (source[i] == '\n') line += 1;
                }
                if (i + 1 >= source.len) return error.UnsupportedFeature;
                i += 2;
            } else {
                while (i < source.len and source[i] != '\n') i += 1;
            }
            continue;
        }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const start = i;
            i += 1;
            while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_')) i += 1;
            const word = source[start..i];
            try tokens.append(allocator, .{ .tag = if (isKeyword(word)) .keyword else .ident, .lexeme = word, .line = line });
            continue;
        }
        if (std.ascii.isDigit(c)) {
            const start = i;
            if (c == '0' and i + 1 < source.len and (source[i + 1] == 'x' or source[i + 1] == 'X')) {
                i += 2;
                while (i < source.len and std.ascii.isHex(source[i])) i += 1;
                if (i == start + 2) return error.UnsupportedFeature;
                try tokens.append(allocator, .{ .tag = .number, .lexeme = source[start..i], .line = line });
                continue;
            }
            i += 1;
            while (i < source.len and (std.ascii.isDigit(source[i]) or source[i] == '.')) i += 1;
            try tokens.append(allocator, .{ .tag = .number, .lexeme = source[start..i], .line = line });
            continue;
        }
        if (c == '[' and i + 1 < source.len and source[i + 1] == '[') {
            i += 2;
            const start_line = line;
            const start = i;
            while (i + 1 < source.len and !(source[i] == ']' and source[i + 1] == ']')) : (i += 1) {
                if (source[i] == '\n') line += 1;
            }
            if (i + 1 >= source.len) return error.UnsupportedFeature;
            try tokens.append(allocator, .{ .tag = .string, .lexeme = source[start..i], .line = start_line });
            i += 2;
            continue;
        }
        if (c == '"' or c == '\'') {
            const quote = c;
            const start_line = line;
            i += 1;
            var bytes: std.ArrayList(u8) = .empty;
            while (i < source.len and source[i] != quote) : (i += 1) {
                if (source[i] == '\\') {
                    i += 1;
                    if (i >= source.len) return error.UnsupportedFeature;
                    const escaped: u8 = switch (source[i]) {
                        'n' => '\n',
                        't' => '\t',
                        'r' => '\r',
                        '\\' => '\\',
                        '"' => '"',
                        '\'' => '\'',
                        else => return error.UnsupportedFeature,
                    };
                    try bytes.append(allocator, escaped);
                } else {
                    if (source[i] == '\n') line += 1;
                    try bytes.append(allocator, source[i]);
                }
            }
            if (i >= source.len) return error.UnsupportedFeature;
            i += 1;
            try tokens.append(allocator, .{ .tag = .string, .lexeme = try bytes.toOwnedSlice(allocator), .line = start_line });
            continue;
        }
        const three = if (i + 2 < source.len) source[i .. i + 3] else "";
        if (three.len == 3 and std.mem.eql(u8, three, "...")) {
            try tokens.append(allocator, .{ .tag = .ellipsis, .lexeme = three, .line = line });
            i += 3;
            continue;
        }
        const two = if (i + 1 < source.len) source[i .. i + 2] else "";
        if (two.len == 2) {
            if (std.mem.eql(u8, two, "::")) {
                try tokens.append(allocator, .{ .tag = .coloncolon, .lexeme = two, .line = line });
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, two, "//")) {
                try tokens.append(allocator, .{ .tag = .floor_div, .lexeme = two, .line = line });
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, two, "..")) {
                try tokens.append(allocator, .{ .tag = .concat, .lexeme = two, .line = line });
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, two, "==")) {
                try tokens.append(allocator, .{ .tag = .eq, .lexeme = two, .line = line });
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, two, "~=")) {
                try tokens.append(allocator, .{ .tag = .ne, .lexeme = two, .line = line });
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, two, "<=")) {
                try tokens.append(allocator, .{ .tag = .le, .lexeme = two, .line = line });
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, two, ">=")) {
                try tokens.append(allocator, .{ .tag = .ge, .lexeme = two, .line = line });
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, two, "<<")) {
                try tokens.append(allocator, .{ .tag = .shl, .lexeme = two, .line = line });
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, two, ">>")) {
                try tokens.append(allocator, .{ .tag = .shr, .lexeme = two, .line = line });
                i += 2;
                continue;
            }
        }
        const tag: TokenTag = switch (c) {
            '(' => .lparen,
            ')' => .rparen,
            '{' => .lbrace,
            '}' => .rbrace,
            '[' => .lbracket,
            ']' => .rbracket,
            ',' => .comma,
            ';' => .semi,
            '.' => .dot,
            '=' => .assign,
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '/' => .slash,
            '%' => .percent,
            '#' => .len,
            '<' => .lt,
            '>' => .gt,
            '&' => .amp,
            '|' => .pipe,
            '~' => .tilde,
            else => return error.UnsupportedFeature,
        };
        try tokens.append(allocator, .{ .tag = tag, .lexeme = source[i .. i + 1], .line = line });
        i += 1;
    }
    return tokens;
}

fn isKeyword(word: []const u8) bool {
    const words = [_][]const u8{ "and", "break", "do", "else", "end", "false", "for", "function", "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while" };
    for (words) |kw| if (std.mem.eql(u8, word, kw)) return true;
    return false;
}

fn isBlockStarter(word: []const u8, previous: []const u8) bool {
    if (std.mem.eql(u8, word, "if") or std.mem.eql(u8, word, "for") or std.mem.eql(u8, word, "function") or std.mem.eql(u8, word, "while") or std.mem.eql(u8, word, "repeat")) return true;
    if (std.mem.eql(u8, word, "do") and !std.mem.eql(u8, previous, "while") and !std.mem.eql(u8, previous, "for")) return true;
    return false;
}

fn binaryPrecedence(token: Token) u8 {
    return switch (token.tag) {
        .keyword => if (std.mem.eql(u8, token.lexeme, "or")) 1 else if (std.mem.eql(u8, token.lexeme, "and")) 2 else 0,
        .eq, .ne, .lt, .le, .gt, .ge => 3,
        .pipe => 4,
        .tilde => 5,
        .amp => 6,
        .shl, .shr => 7,
        .concat => 8,
        .plus, .minus => 9,
        .star, .slash, .floor_div, .percent => 10,
        else => 0,
    };
}

fn parseNumber(text: []const u8) !Value {
    if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X")) {
        return .{ .integer = try std.fmt.parseInt(i64, text[2..], 16) };
    }
    if (std.mem.indexOfScalar(u8, text, '.')) |_| return .{ .float = try std.fmt.parseFloat(f64, text) };
    return .{ .integer = try std.fmt.parseInt(i64, text, 10) };
}

fn numberFromFloatIntegral(value: f64) Value {
    const int_value: i64 = @intFromFloat(value);
    if (@as(f64, @floatFromInt(int_value)) == value) return .{ .integer = int_value };
    return .{ .float = value };
}

fn valueToNumber(value: Value) !f64 {
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => error.RuntimeError,
    };
}

fn valueToInteger(value: Value) !i64 {
    return switch (value) {
        .integer => |i| i,
        .float => |f| {
            if (f != f) return error.RuntimeError;
            if (@floor(f) != f) return error.RuntimeError;
            if (f < @as(f64, @floatFromInt(std.math.minInt(i64))) or
                f > @as(f64, @floatFromInt(std.math.maxInt(i64)))) return error.RuntimeError;
            return @intFromFloat(f);
        },
        else => error.RuntimeError,
    };
}

fn unaryMinus(value: Value) !Value {
    return switch (value) {
        .integer => |i| .{ .integer = -i },
        .float => |f| .{ .float = -f },
        else => error.RuntimeError,
    };
}

fn lengthValue(value: Value) !Value {
    return switch (value) {
        .string => |s| .{ .integer = @intCast(s.len) },
        .table => |t| .{ .integer = t.length() },
        else => error.RuntimeError,
    };
}

fn bitNot(value: Value) !Value {
    return .{ .integer = ~(try valueToInteger(value)) };
}

fn applyBinary(allocator: std.mem.Allocator, op: Token, left: Value, right: Value) !Value {
    return switch (op.tag) {
        .plus, .minus, .star, .slash, .floor_div, .percent => arithmetic(op.tag, left, right),
        .concat => concat(allocator, left, right),
        .eq, .ne, .lt, .le, .gt, .ge => compare(op.tag, left, right),
        .amp, .pipe, .tilde, .shl, .shr => bitwise(op.tag, left, right),
        else => error.UnsupportedFeature,
    };
}

fn arithmetic(tag: TokenTag, left: Value, right: Value) !Value {
    if (tag != .slash and left == .integer and right == .integer) {
        const a = left.integer;
        const b = right.integer;
        return switch (tag) {
            .plus => .{ .integer = a + b },
            .minus => .{ .integer = a - b },
            .star => .{ .integer = a * b },
            .floor_div => .{ .integer = @divFloor(a, b) },
            .percent => .{ .integer = @mod(a, b) },
            else => unreachable,
        };
    }
    const a = try valueToNumber(left);
    const b = try valueToNumber(right);
    return switch (tag) {
        .plus => numberFromFloatIntegral(a + b),
        .minus => numberFromFloatIntegral(a - b),
        .star => numberFromFloatIntegral(a * b),
        .slash => .{ .float = a / b },
        .floor_div => numberFromFloatIntegral(@floor(a / b)),
        .percent => numberFromFloatIntegral(a - @floor(a / b) * b),
        else => unreachable,
    };
}

fn concat(allocator: std.mem.Allocator, left: Value, right: Value) !Value {
    const l = try valueToStringForConcat(allocator, left);
    const r = try valueToStringForConcat(allocator, right);
    return .{ .string = try std.mem.concat(allocator, u8, &.{ l, r }) };
}

fn valueToStringForConcat(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        else => error.RuntimeError,
    };
}

fn compare(tag: TokenTag, left: Value, right: Value) !Value {
    const result = switch (tag) {
        .eq => valuesEqual(left, right),
        .ne => !valuesEqual(left, right),
        .lt, .le, .gt, .ge => try orderedCompare(tag, left, right),
        else => unreachable,
    };
    return .{ .boolean = result };
}

fn valuesEqual(left: Value, right: Value) bool {
    if ((left == .integer or left == .float) and (right == .integer or right == .float)) {
        const a = valueToNumber(left) catch return false;
        const b = valueToNumber(right) catch return false;
        return a == b;
    }
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .nil => true,
        .boolean => |v| v == right.boolean,
        .integer => |v| v == right.integer,
        .float => |v| v == right.float,
        .string => |v| std.mem.eql(u8, v, right.string),
        .table => |v| v == right.table,
        .function => |v| v == right.function,
        .builtin => |v| v == right.builtin,
    };
}

fn orderedCompare(tag: TokenTag, left: Value, right: Value) !bool {
    const a = try valueToNumber(left);
    const b = try valueToNumber(right);
    return switch (tag) {
        .lt => a < b,
        .le => a <= b,
        .gt => a > b,
        .ge => a >= b,
        else => unreachable,
    };
}

fn bitwise(tag: TokenTag, left: Value, right: Value) !Value {
    const a = try valueToInteger(left);
    const b = try valueToInteger(right);
    return .{ .integer = switch (tag) {
        .amp => a & b,
        .pipe => a | b,
        .tilde => a ^ b,
        .shl => shiftBits(a, b),
        .shr => shiftBits(a, -b),
        else => unreachable,
    } };
}

fn shiftBits(value: i64, amount: i64) i64 {
    if (amount == 0) return value;
    const bits: u64 = @bitCast(value);
    if (amount > 0) {
        if (amount >= 64) return 0;
        const shift: u6 = @intCast(amount);
        return @bitCast(bits << shift);
    }
    const positive = -amount;
    if (positive >= 64) return 0;
    const shift: u6 = @intCast(positive);
    return @bitCast(bits >> shift);
}

test "vm level0 literals locals arithmetic strings tables control flow and bitwise" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippets = [_]struct { source: []const u8, stdout: []const u8 }{
        .{ .source = "print(nil, true, false, 42, 3.5, \"literal\")\n", .stdout = "nil\ttrue\tfalse\t42\t3.5\tliteral\n" },
        .{ .source = "print([[long literal]], 0x10)\nlocal s = 1; local t = 2; print(s + t)\n", .stdout = "long literal\t16\n3\n" },
        .{ .source = "local x = 1\nlocal y = x + 1\nprint(y, x)\ndo\n  local x = y + 1\n  print(x)\nend\n", .stdout = "2\t1\n3\n" },
        .{ .source = "local a, b = 7, 2\nprint(a + b - 2, a - b, a * b - 2, a / b, a // b, a % b, -a)\n", .stdout = "7\t5\t12\t3.5\t3\t1\t-7\n" },
        .{ .source = "local s = \"lua\" .. \"-\" .. \"55\"\nprint(s, #s, \"a\\n\" == \"a\\n\")\n", .stdout = "lua-55\t6\ttrue\n" },
        .{ .source = "local t = {1, 2, 3, name = \"lua\"}\nt[2] = 22\nt.extra = \"three\"\nprint(t[1], t[2], t.extra, #t)\n", .stdout = "1\t22\tthree\t3\n" },
        .{ .source = "local sum = 0\nfor i = 1, 5 do\n  if i % 2 == 0 then sum = sum + i end\nend\nlocal n = 0\nwhile n < 3 do n = n + 1 end\nrepeat\n  sum = sum + n\n  break\nuntil false\nprint(sum + ((true and 10) or 0))\nprint(n)\n", .stdout = "19\n3\n" },
        .{ .source = "local a, b = 6, 3\nprint(a > b, a >= 6, b < a, b <= 3, a == 6, a ~= b)\nprint((false or \"fallback\") and \"ok\")\nprint(a & b, a | b, a ~ b, a << 1, a >> 1, ~b)\n", .stdout = "true\ttrue\ttrue\ttrue\ttrue\ttrue\nok\n2\t7\t5\t12\t3\t-4\n" },
        .{ .source = "print(1 << 63, 1 << 64, -1 >> 1, -1 >> 64, 8 << -1, 8 >> -1)\nprint(15.0 & 7, 15.0 | 2, 8.0 << 1)\n", .stdout = "-9223372036854775808\t0\t9223372036854775807\t0\t4\t16\n7\t15\t16\n" },
        .{ .source = "local value = \"initial\"\nif false then\n  value = \"then-branch\"\nelse\n  value = \"else-branch\"\nend\nprint(value)\n", .stdout = "else-branch\n" },
        .{ .source = "local i = \"outer\"\nlocal total = 0\nfor i = 1, 3 do\n  total = total + i\nend\nprint(i, total)\n", .stdout = "outer\t6\n" },
        .{ .source = "local a = false and (missing + 1)\nlocal b = true or (missing + 1)\nprint(a, b)\n", .stdout = "false\ttrue\n" },
        .{ .source = "print(1 == 1.0, 1 ~= 1.0)\n", .stdout = "true\tfalse\n" },
        .{ .source = "local x = 0\ngoto skip\nx = 99\n::skip::\nx = x + 1\nprint(x)\n", .stdout = "1\n" },
        .{ .source = "local preload_value = \"debug words are data\"\nlocal loader_count = 9\nprint(preload_value, loader_count)\n", .stdout = "debug words are data\t9\n" },
    };
    for (snippets) |snippet| {
        const result = try runLevel0(arena.allocator(), snippet.source);
        try std.testing.expectEqual(VmState.pass, result.state);
        try std.testing.expectEqual(@as(u8, 0), result.exit_code);
        try std.testing.expectEqualSlices(u8, snippet.stdout, result.stdout);
        _ = arena.reset(.retain_capacity);
    }
}

test "vm level0 goto label legality diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippets = [_]struct { source: []const u8, diagnostic: []const u8 }{
        .{ .source = "goto missing\n", .diagnostic = "syntax-error:1:no visible label 'missing' for <goto> at line 1" },
        .{ .source = "::a::\n::a::\n", .diagnostic = "syntax-error:2:label 'a' already defined on line 2" },
        .{ .source = "::1::\n", .diagnostic = "syntax-error:1:<name> expected near '1'" },
        .{ .source = "goto end\n", .diagnostic = "syntax-error:1:<name> expected near 'end'" },
        .{ .source = "goto L\nlocal x\n::L::\nprint(1)\n", .diagnostic = "syntax-error:4:<goto L> at line 1 jumps into the scope of 'x'" },
    };
    for (snippets) |snippet| {
        const result = try runLevel0(arena.allocator(), snippet.source);
        try std.testing.expectEqual(VmState.runtime_error, result.state);
        try std.testing.expectEqual(@as(u8, 1), result.exit_code);
        try std.testing.expectEqualSlices(u8, "", result.stdout);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, snippet.diagnostic) != null);
        _ = arena.reset(.retain_capacity);
    }
}

test "vm level1 direct calls varargs multi returns env globals and tail calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippets = [_]struct { source: []const u8, stdout: []const u8 }{
        .{ .source = "local function add(a, b) return a + b end\nlocal function twice(x) return add(x, x) end\nprint(add(twice(5), 5))\n", .stdout = "15\n" },
        .{ .source = "local x = 0\nlocal function setx() x = 3 end\nsetx()\nprint(x)\n", .stdout = "3\n" },
        .{ .source = "local function count(...)\n  local t = {...}\n  return #t, t[1], t[#t]\nend\nprint(count(1, 2, 3, 4))\n", .stdout = "4\t1\t4\n" },
        .{ .source = "local function pack(...)\n  local n = select(\"#\", ...)\n  local a, b, c = ...\n  return n, a, c\nend\nprint(pack(nil, \"x\", 3))\n", .stdout = "3\tnil\t3\n" },
        .{ .source = "local function outer(...)\n  local function inner(...) return ... end\n  return inner()\nend\nprint(outer(1, 2))\n", .stdout = "\n" },
        .{ .source = "local function values() return 1, 2, 3 end\nlocal a, b, c = values()\nlocal d = 4\nlocal t = {values()}\nprint(a, b, c, d, #t)\n", .stdout = "1\t2\t3\t4\t3\n" },
        .{ .source = "local function finish(x) return \"done\", x end\nlocal function bounce(x)\n  if x == 0 then return finish(9) end\n  return bounce(x - 1)\nend\nprint(bounce(3))\n", .stdout = "done\t9\n" },
        .{ .source = "local function f(a, b, c) return c, b end\nlocal function g() return f(1, 2) end\nlocal a, b = g()\nprint(a, b)\n", .stdout = "nil\t2\n" },
        .{ .source = "local _ENV = { print = print, value = 21 }\nprint(value)\n", .stdout = "21\n" },
        .{ .source = "local function f() x = 7 return x end\nprint(f(), x)\nx = nil\n", .stdout = "7\t7\n" },
        .{ .source = "local env = { print = print }\nlocal _ENV = env\nlocal function f() x = 7 return x end\nprint(f(), env.x, x)\n", .stdout = "7\t7\t7\n" },
        .{ .source = "local env1 = { print = print, value = 1 }\nlocal env2 = { print = print, value = 2 }\nlocal _ENV = env1\nlocal function f() return value end\ndo\n  local _ENV = env2\n  print(f())\nend\n", .stdout = "1\n" },
        .{ .source = "local env1 = { print = print }\nlocal env2 = { print = print }\nlocal _ENV = env1\nlocal function f() x = 11 return x end\ndo\n  local _ENV = env2\n  print(f(), env1.x, env2.x)\nend\n", .stdout = "11\t11\tnil\n" },
        .{ .source = "local env = { print = print, value = 1 }\nlocal _ENV = env\nlocal function f() return value end\ndo\n  local value = 2\n  print(f())\nend\n", .stdout = "1\n" },
        .{ .source = "corpus_global_value = 31\nprint(corpus_global_value)\ncorpus_global_value = nil\n", .stdout = "31\n" },
    };
    for (snippets) |snippet| {
        const result = try runLevel0(arena.allocator(), snippet.source);
        try std.testing.expectEqual(VmState.pass, result.state);
        try std.testing.expectEqual(@as(u8, 0), result.exit_code);
        try std.testing.expectEqualSlices(u8, snippet.stdout, result.stdout);
        _ = arena.reset(.retain_capacity);
    }
}

test "advanced api names are local bindings before fallback classification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippets = [_]struct { source: []const u8, stdout: []const u8 }{
        .{
            .source = "local rawget, rawset, rawequal, rawlen = 1, 2, 3, 4\nlocal collectgarbage, coroutine = 5, 6\nlocal pairs, ipairs, next = 7, 8, 9\nlocal pcall, xpcall, error, setmetatable = 10, 11, 12, 13\nprint(rawget, rawset, rawequal, rawlen)\nprint(collectgarbage, coroutine, pairs, ipairs, next)\nprint(pcall, xpcall, error, setmetatable)\n",
            .stdout = "1\t2\t3\t4\n5\t6\t7\t8\t9\n10\t11\t12\t13\n",
        },
        .{
            .source = "local function pcall(rawget) return rawget + 1 end\nlocal function setmetatable(error) return pcall(error + 1) end\nprint(setmetatable(5))\n",
            .stdout = "7\n",
        },
        .{
            .source = "local t = { rawget = 3, setmetatable = 4 }\nprint(t.rawget, t.setmetatable)\n",
            .stdout = "3\t4\n",
        },
        .{
            .source = "repeat\n  local rawget = true\nuntil rawget\nprint(\"repeat-shadow\")\n",
            .stdout = "repeat-shadow\n",
        },
    };
    for (snippets) |snippet| {
        const result = try runLevel0(arena.allocator(), snippet.source);
        try std.testing.expectEqual(VmState.pass, result.state);
        try std.testing.expectEqual(@as(u8, 0), result.exit_code);
        try std.testing.expectEqualSlices(u8, snippet.stdout, result.stdout);
        try std.testing.expectEqualSlices(u8, "", result.stderr);
        _ = arena.reset(.retain_capacity);
    }
}

test "real advanced api globals still classify with stable fallback reasons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippets = [_]struct { source: []const u8, reason: []const u8 }{
        .{ .source = "local t = {}\nprint(rawget(t, \"x\"))\n", .reason = "raw-ops" },
        .{ .source = "local t = {}\nif false then\n  local rawget = 1\nelse\n  print(rawget(t, \"x\"))\nend\n", .reason = "raw-ops" },
        .{ .source = "local t = {}\nif false then\n  local rawget = 1\nelseif true then\n  print(rawget(t, \"x\"))\nend\n", .reason = "raw-ops" },
        .{ .source = "local t = {}\nsetmetatable(t, {})\n", .reason = "metatable-dispatch" },
        .{ .source = "print(pcall(function() error(\"boom\") end))\n", .reason = "protected-error" },
        .{ .source = "local t = {1, 2}\nfor k in pairs(t) do print(k) end\n", .reason = "table-iteration" },
    };
    for (snippets) |snippet| {
        const result = try runLevel0(arena.allocator(), snippet.source);
        try std.testing.expectEqual(VmState.unsupported, result.state);
        try std.testing.expectEqual(@as(u8, 1), result.exit_code);
        try std.testing.expectEqualStrings(snippet.reason, result.unsupported_reason.?);
        _ = arena.reset(.retain_capacity);
    }
}

test "vm level1 closures and dynamic features are explicitly unsupported fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippets = [_]struct { source: []const u8, reason: []const u8 }{
        .{ .source = "local function counter(start)\n  return function() return start end\nend\nprint(counter(1)())\n", .reason = "closure-upvalues" },
        .{ .source = "local function outer(x)\n  local function inner() return x end\n  return inner\nend\nlocal f = outer(5)\nprint(f())\n", .reason = "closure-upvalues" },
        .{ .source = "local function outer(x)\n  local function inner() return x end\n  local alias = inner\n  return alias\nend\nlocal f = outer(5)\nprint(f())\n", .reason = "closure-upvalues" },
        .{ .source = "local function outer(x)\n  local function inner() return x end\n  local alias = inner\n  return (\n    alias\n  )\nend\nlocal f = outer(5)\nprint(f())\n", .reason = "closure-upvalues" },
        .{ .source = "local function outer(x)\n  local function inner() return x end\n  local alias = (inner)\n  return alias\nend\nlocal f = outer(5)\nprint(f())\n", .reason = "closure-upvalues" },
        .{ .source = "local function outer(x)\n  local function inner() return x end\n  local alias\n  alias = (inner)\n  return alias\nend\nlocal f = outer(5)\nprint(f())\n", .reason = "closure-upvalues" },
        .{ .source = "local function outer(x)\n  local function inner() return x end\n  local first, second = nil, inner\n  return second\nend\nlocal f = outer(5)\nprint(f())\n", .reason = "closure-upvalues" },
        .{ .source = "local function outer(x)\n  local function inner() return x end\n  local first, second\n  first, second = nil, inner\n  return second\nend\nlocal f = outer(5)\nprint(f())\n", .reason = "closure-upvalues" },
        .{ .source = "local function outer(x)\n  local function inner() return x end\n  escaped = inner\nend\nouter(5)\nprint(escaped())\nescaped = nil\n", .reason = "closure-upvalues" },
        .{ .source = "local function outer(x)\n  local function inner() return x end\n  local box = {}\n  box.fn = inner\n  return box.fn\nend\nlocal f = outer(5)\nprint(f())\n", .reason = "closure-upvalues" },
        .{ .source = "load(\"print(1)\")()\n", .reason = "load" },
        .{ .source = "_ENV = {}\nprint(1)\n", .reason = "dynamic-env-mutation" },
    };
    for (snippets) |snippet| {
        const result = try runLevel0(arena.allocator(), snippet.source);
        try std.testing.expectEqual(VmState.unsupported, result.state);
        try std.testing.expectEqual(@as(u8, 1), result.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unsupported/fallback") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, snippet.reason) != null);
        _ = arena.reset(.retain_capacity);
    }
}

test "vm level1 print resolves through lexical environment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runLevel0(arena.allocator(), "local _ENV = { value = 21 }\nprint(value)\n");
    try std.testing.expectEqual(VmState.runtime_error, result.state);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualSlices(u8, "", result.stdout);
}
