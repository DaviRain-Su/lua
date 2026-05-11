const std = @import("std");
const advanced_hooks = @import("advanced_hooks.zig");
const vm_table = @import("vm_table.zig");

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
    colon,
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
    captures: std.StringHashMap(*Cell),
};

const Builtin = enum {
    print,
    select,
    pairs,
    ipairs,
    next,
    ipairs_iter,
    rawget,
    rawset,
    rawequal,
    rawlen,
    setmetatable,
    getmetatable,
    tostring,
    type,
    lua_error,
    pcall,
    xpcall,
    coroutine_create,
    coroutine_resume,
    coroutine_yield,
    coroutine_status,
    coroutine_close,
    coroutine_wrap,
    coroutine_running,
    coroutine_isyieldable,
    // math library
    math_abs,
    math_ceil,
    math_floor,
    math_sqrt,
    math_max,
    math_min,
    math_exp,
    math_log,
    math_sin,
    math_cos,
    math_tan,
    math_asin,
    math_acos,
    math_atan,
    math_deg,
    math_rad,
    math_fmod,
    math_modf,
    math_frexp,
    math_ldexp,
    math_ult,
    math_tointeger,
    math_type,
    math_random,
    math_randomseed,
    // string library
    string_len,
    string_sub,
    string_rep,
    string_reverse,
    string_upper,
    string_lower,
    string_byte,
    string_char,
    string_format,
    string_find,
    string_match,
    string_gmatch,
    string_gsub,
    string_dump,
    // table library
    table_insert,
    table_remove,
    table_sort,
    table_concat,
    table_move,
    table_pack,
    table_unpack,
    table_create,
    // io library
    io_open,
    io_close,
    io_read,
    io_write,
    io_lines,
    io_type,
    io_flush,
    io_tmpfile,
    io_input,
    io_output,
    io_popen,
};

const ValueTag = enum { nil, boolean, integer, float, string, table, function, builtin, thread, wrapped_thread };

const Value = union(ValueTag) {
    nil: void,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    table: *Table,
    function: *Function,
    builtin: Builtin,
    thread: *Thread,
    wrapped_thread: *Thread,

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

const Cell = struct {
    value: Value,
};

const CoroutineStatus = enum { suspended, running, normal, dead };

const CoroutineContinuationKind = enum {
    resume_body,
    pending_local_assignment,
    pending_assignment,
    pending_return,
    pending_protected_call,
    pending_expression,
    pending_binary,
    pending_call,
};

const CoroutineContinuation = struct {
    kind: CoroutineContinuationKind,
    local_name: ?[]const u8,
    local_names: []const []const u8,
    assign_targets: []const AssignTarget,
    prefix_values: []const Value,
    pos: usize,
    body_end: usize,
    expression_min_prec: u8 = 0,
    binary_left: Value = .{ .nil = {} },
    binary_op: Token = .{ .tag = .eof, .lexeme = "", .line = 1 },
    call_callee: Value = .{ .nil = {} },
    call_open_line: usize = 1,
    call_prepend_callee: bool = false,
};

const Thread = struct {
    vm: Vm,
    function: *Function,
    status: CoroutineStatus,
    continuations: std.ArrayList(CoroutineContinuation),
    yield_values: []const Value,
    close_error: ?Value,
};

const Table = struct {
    array: std.ArrayList(Value),
    integers: std.AutoHashMap(i64, Value),
    floats: std.AutoHashMap(u64, Value),
    strings: std.StringHashMap(Value),
    table_keys: std.AutoHashMap(*Table, Value),
    function_keys: std.AutoHashMap(*Function, Value),
    builtin_keys: std.AutoHashMap(Builtin, Value),
    thread_keys: std.AutoHashMap(*Thread, Value),
    bool_true: Value,
    bool_false: Value,
    metatable: ?*Table,

    fn create(allocator: std.mem.Allocator) !*Table {
        const table = try allocator.create(Table);
        table.* = .{
            .array = .empty,
            .integers = std.AutoHashMap(i64, Value).init(allocator),
            .floats = std.AutoHashMap(u64, Value).init(allocator),
            .strings = std.StringHashMap(Value).init(allocator),
            .table_keys = std.AutoHashMap(*Table, Value).init(allocator),
            .function_keys = std.AutoHashMap(*Function, Value).init(allocator),
            .builtin_keys = std.AutoHashMap(Builtin, Value).init(allocator),
            .thread_keys = std.AutoHashMap(*Thread, Value).init(allocator),
            .bool_true = .{ .nil = {} },
            .bool_false = .{ .nil = {} },
            .metatable = null,
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

    fn rawSetKey(self: *Table, allocator: std.mem.Allocator, key: Value, value: Value) !void {
        switch (key) {
            .nil => return error.RuntimeError,
            .integer => |i| try self.setIndex(allocator, i, value),
            .float => |f| {
                if (floatToInteger(f, .eq)) |i| {
                    try self.setIndex(allocator, i, value);
                } else {
                    if (f != f) return error.RuntimeError;
                    try self.floats.put(floatTableKey(f), value);
                }
            },
            .string => |s| try self.setString(s, value),
            .table => |t| try self.table_keys.put(t, value),
            .function => |f| try self.function_keys.put(f, value),
            .builtin => |b| try self.builtin_keys.put(b, value),
            .thread => |t| try self.thread_keys.put(t, value),
            .wrapped_thread => |t| try self.thread_keys.put(t, value),
            .boolean => |b| {
                if (b) {
                    self.bool_true = value;
                } else {
                    self.bool_false = value;
                }
            },
        }
    }

    fn rawGetKey(self: *Table, key: Value) !Value {
        return switch (key) {
            .nil => .{ .nil = {} },
            .integer => |i| self.getIndex(i),
            .float => |f| if (floatToInteger(f, .eq)) |i|
                self.getIndex(i)
            else if (f != f)
                .{ .nil = {} }
            else
                self.floats.get(floatTableKey(f)) orelse .{ .nil = {} },
            .string => |s| self.getString(s),
            .table => |t| self.table_keys.get(t) orelse .{ .nil = {} },
            .function => |f| self.function_keys.get(f) orelse .{ .nil = {} },
            .builtin => |b| self.builtin_keys.get(b) orelse .{ .nil = {} },
            .thread => |t| self.thread_keys.get(t) orelse .{ .nil = {} },
            .wrapped_thread => |t| self.thread_keys.get(t) orelse .{ .nil = {} },
            .boolean => |b| if (b) self.bool_true else self.bool_false,
        };
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

    fn destroy(self: *Table, allocator: std.mem.Allocator) void {
        self.integers.deinit();
        self.floats.deinit();
        self.strings.deinit();
        self.table_keys.deinit();
        self.function_keys.deinit();
        self.builtin_keys.deinit();
        self.thread_keys.deinit();
        self.array.deinit(allocator);
        allocator.destroy(self);
    }

    /// Iterate to next key/value pair after the given key.
    /// Pass null to start from the beginning.
    /// Returns null when iteration is complete.
    /// Iteration order: array part (integer keys 1..n), then hash part
    /// (negative integers, floats, strings, booleans).
    fn next(self: *Table, key: ?Value) ?struct { key: Value, value: Value } {
        if (key == null) {
            // Start from array part
            if (self.array.items.len > 0) {
                var i: usize = 0;
                while (i < self.array.items.len) : (i += 1) {
                    if (!self.array.items[i].isNil()) {
                        return .{ .key = .{ .integer = @intCast(i + 1) }, .value = self.array.items[i] };
                    }
                }
            }
            // Fall through to hash part
            return self.nextHashPart(null);
        }

        const k = key.?;
        switch (k) {
            .integer => |i| {
                if (i >= 1) {
                    // Continue array part from next slot
                    var idx: usize = @intCast(i);
                    while (idx < self.array.items.len) : (idx += 1) {
                        if (!self.array.items[idx].isNil()) {
                            return .{ .key = .{ .integer = @intCast(idx + 1) }, .value = self.array.items[idx] };
                        }
                    }
                    // Fall through to hash part
                    return self.nextHashPart(null);
                }
                // Negative integer: in hash part
                return self.nextHashPartAfterKey(k);
            },
            else => return self.nextHashPartAfterKey(k),
        }
    }

    fn nextHashPart(self: *Table, start_hint: ?void) ?struct { key: Value, value: Value } {
        _ = start_hint;
        // Negative integers
        var iter = self.integers.iterator();
        if (iter.next()) |entry| {
            return .{ .key = .{ .integer = entry.key_ptr.* }, .value = entry.value_ptr.* };
        }
        // Floats
        var fiter = self.floats.iterator();
        if (fiter.next()) |entry| {
            const f: f64 = @bitCast(entry.key_ptr.*);
            return .{ .key = .{ .float = f }, .value = entry.value_ptr.* };
        }
        // Strings
        var siter = self.strings.iterator();
        if (siter.next()) |entry| {
            return .{ .key = .{ .string = entry.key_ptr.* }, .value = entry.value_ptr.* };
        }
        // Booleans
        if (!self.bool_true.isNil()) {
            return .{ .key = .{ .boolean = true }, .value = self.bool_true };
        }
        if (!self.bool_false.isNil()) {
            return .{ .key = .{ .boolean = false }, .value = self.bool_false };
        }
        return null;
    }

    fn nextHashPartAfterKey(self: *Table, after: Value) ?struct { key: Value, value: Value } {
        switch (after) {
            .integer => |i| {
                var found = false;
                var iter = self.integers.iterator();
                while (iter.next()) |entry| {
                    if (!found) {
                        if (entry.key_ptr.* == i) found = true;
                        continue;
                    }
                    return .{ .key = .{ .integer = entry.key_ptr.* }, .value = entry.value_ptr.* };
                }
                if (!found) return null;
                return self.nextHashFromFloats();
            },
            .float => |f| {
                const after_key = floatTableKey(f);
                var found = false;
                var iter = self.floats.iterator();
                while (iter.next()) |entry| {
                    if (!found) {
                        if (entry.key_ptr.* == after_key) found = true;
                        continue;
                    }
                    const fv: f64 = @bitCast(entry.key_ptr.*);
                    return .{ .key = .{ .float = fv }, .value = entry.value_ptr.* };
                }
                if (!found) return null;
                return self.nextHashFromStrings();
            },
            .string => |s| {
                var found = false;
                var iter = self.strings.iterator();
                while (iter.next()) |entry| {
                    if (!found) {
                        if (std.mem.eql(u8, entry.key_ptr.*, s)) found = true;
                        continue;
                    }
                    return .{ .key = .{ .string = entry.key_ptr.* }, .value = entry.value_ptr.* };
                }
                if (!found) return null;
                if (!self.bool_true.isNil()) {
                    return .{ .key = .{ .boolean = true }, .value = self.bool_true };
                }
                if (!self.bool_false.isNil()) {
                    return .{ .key = .{ .boolean = false }, .value = self.bool_false };
                }
                return null;
            },
            else => return null,
        }
    }

    fn nextHashFromFloats(self: *Table) ?struct { key: Value, value: Value } {
        var iter = self.floats.iterator();
        if (iter.next()) |entry| {
            const f: f64 = @bitCast(entry.key_ptr.*);
            return .{ .key = .{ .float = f }, .value = entry.value_ptr.* };
        }
        return self.nextHashFromStrings();
    }

    fn nextHashFromStrings(self: *Table) ?struct { key: Value, value: Value } {
        var iter = self.strings.iterator();
        if (iter.next()) |entry| {
            return .{ .key = .{ .string = entry.key_ptr.* }, .value = entry.value_ptr.* };
        }
        if (!self.bool_true.isNil()) {
            return .{ .key = .{ .boolean = true }, .value = self.bool_true };
        }
        if (!self.bool_false.isNil()) {
            return .{ .key = .{ .boolean = false }, .value = self.bool_false };
        }
        return null;
    }

    fn rawMetafield(self: *Table, name: []const u8) Value {
        if (self.metatable) |mt| return mt.getString(name);
        return .{ .nil = {} };
    }
};

const Scope = struct {
    vars: std.StringHashMap(*Cell),
    varargs: []const Value,
    has_varargs: bool,
};

const CallFrame = struct {
    scope_start: usize,
    lexical_scope_len: usize,
    env: ?*Table,
    captures: *std.StringHashMap(*Cell),
    body_end: usize,
    call_line: ?usize,
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
    key_value: Value = .{ .nil = {} },
    key_index: i64 = 0,
};

const Vm = struct {
    allocator: std.mem.Allocator,
    tokens: []const Token,
    stdout: std.Io.Writer.Allocating,
    scopes: std.ArrayList(Scope),
    frames: std.ArrayList(CallFrame),
    runtime_error_message: ?[]const u8,
    runtime_error_value: ?Value,
    runtime_error_line: usize,
    runtime_error_metamethod: ?[]const u8,
    current_thread: ?*Thread,
    syntax_error_message: ?[]const u8,
    syntax_error_line: usize,
    error_chunk_name: []const u8,
    error_line_offset: usize,

    fn init(allocator: std.mem.Allocator, tokens: []const Token) !Vm {
        return initWithVarargs(allocator, tokens, &.{});
    }

    fn initWithVarargs(allocator: std.mem.Allocator, tokens: []const Token, varargs: []const Value) !Vm {
        return initWithContext(allocator, tokens, varargs, "stdin", 0);
    }

    fn initWithContext(
        allocator: std.mem.Allocator,
        tokens: []const Token,
        varargs: []const Value,
        error_chunk_name: []const u8,
        error_line_offset: usize,
    ) !Vm {
        var vm = Vm{
            .allocator = allocator,
            .tokens = tokens,
            .stdout = std.Io.Writer.Allocating.init(allocator),
            .scopes = .empty,
            .frames = .empty,
            .runtime_error_message = null,
            .runtime_error_value = null,
            .runtime_error_line = 1,
            .runtime_error_metamethod = null,
            .current_thread = null,
            .syntax_error_message = null,
            .syntax_error_line = 1,
            .error_chunk_name = error_chunk_name,
            .error_line_offset = error_line_offset,
        };
        try vm.pushScope(varargs, varargs.len > 0);
        const default_env = try Table.create(allocator);
        try default_env.setString("print", .{ .builtin = .print });
        try default_env.setString("select", .{ .builtin = .select });
        try default_env.setString("pairs", .{ .builtin = .pairs });
        try default_env.setString("ipairs", .{ .builtin = .ipairs });
        try default_env.setString("next", .{ .builtin = .next });
        try default_env.setString("rawget", .{ .builtin = .rawget });
        try default_env.setString("rawset", .{ .builtin = .rawset });
        try default_env.setString("rawequal", .{ .builtin = .rawequal });
        try default_env.setString("rawlen", .{ .builtin = .rawlen });
        try default_env.setString("setmetatable", .{ .builtin = .setmetatable });
        try default_env.setString("getmetatable", .{ .builtin = .getmetatable });
        try default_env.setString("tostring", .{ .builtin = .tostring });
        try default_env.setString("type", .{ .builtin = .type });
        try default_env.setString("error", .{ .builtin = .lua_error });
        try default_env.setString("pcall", .{ .builtin = .pcall });
        try default_env.setString("xpcall", .{ .builtin = .xpcall });
        const coroutine_table = try Table.create(allocator);
        try coroutine_table.setString("create", .{ .builtin = .coroutine_create });
        try coroutine_table.setString("resume", .{ .builtin = .coroutine_resume });
        try coroutine_table.setString("yield", .{ .builtin = .coroutine_yield });
        try coroutine_table.setString("status", .{ .builtin = .coroutine_status });
        try coroutine_table.setString("close", .{ .builtin = .coroutine_close });
        try coroutine_table.setString("wrap", .{ .builtin = .coroutine_wrap });
        try coroutine_table.setString("running", .{ .builtin = .coroutine_running });
        try coroutine_table.setString("isyieldable", .{ .builtin = .coroutine_isyieldable });
        try default_env.setString("coroutine", .{ .table = coroutine_table });
        try default_env.setString("_G", .{ .table = default_env });

        // math library
        const math_table = try Table.create(allocator);
        try math_table.setString("abs", .{ .builtin = .math_abs });
        try math_table.setString("ceil", .{ .builtin = .math_ceil });
        try math_table.setString("floor", .{ .builtin = .math_floor });
        try math_table.setString("sqrt", .{ .builtin = .math_sqrt });
        try math_table.setString("max", .{ .builtin = .math_max });
        try math_table.setString("min", .{ .builtin = .math_min });
        try math_table.setString("exp", .{ .builtin = .math_exp });
        try math_table.setString("log", .{ .builtin = .math_log });
        try math_table.setString("sin", .{ .builtin = .math_sin });
        try math_table.setString("cos", .{ .builtin = .math_cos });
        try math_table.setString("tan", .{ .builtin = .math_tan });
        try math_table.setString("asin", .{ .builtin = .math_asin });
        try math_table.setString("acos", .{ .builtin = .math_acos });
        try math_table.setString("atan", .{ .builtin = .math_atan });
        try math_table.setString("deg", .{ .builtin = .math_deg });
        try math_table.setString("rad", .{ .builtin = .math_rad });
        try math_table.setString("fmod", .{ .builtin = .math_fmod });
        try math_table.setString("modf", .{ .builtin = .math_modf });
        try math_table.setString("frexp", .{ .builtin = .math_frexp });
        try math_table.setString("ldexp", .{ .builtin = .math_ldexp });
        try math_table.setString("ult", .{ .builtin = .math_ult });
        try math_table.setString("tointeger", .{ .builtin = .math_tointeger });
        try math_table.setString("type", .{ .builtin = .math_type });
        try math_table.setString("random", .{ .builtin = .math_random });
        try math_table.setString("randomseed", .{ .builtin = .math_randomseed });
        // math constants
        try math_table.setString("pi", .{ .float = std.math.pi });
        try math_table.setString("huge", .{ .float = std.math.inf(f64) });
        try math_table.setString("maxinteger", .{ .integer = std.math.maxInt(i64) });
        try math_table.setString("mininteger", .{ .integer = std.math.minInt(i64) });
        try default_env.setString("math", .{ .table = math_table });

        // string library
        const string_table = try Table.create(allocator);
        try string_table.setString("len", .{ .builtin = .string_len });
        try string_table.setString("sub", .{ .builtin = .string_sub });
        try string_table.setString("rep", .{ .builtin = .string_rep });
        try string_table.setString("reverse", .{ .builtin = .string_reverse });
        try string_table.setString("upper", .{ .builtin = .string_upper });
        try string_table.setString("lower", .{ .builtin = .string_lower });
        try string_table.setString("byte", .{ .builtin = .string_byte });
        try string_table.setString("char", .{ .builtin = .string_char });
        try string_table.setString("format", .{ .builtin = .string_format });
        try string_table.setString("find", .{ .builtin = .string_find });
        try string_table.setString("match", .{ .builtin = .string_match });
        try string_table.setString("gmatch", .{ .builtin = .string_gmatch });
        try string_table.setString("gsub", .{ .builtin = .string_gsub });
        try string_table.setString("dump", .{ .builtin = .string_dump });
        try default_env.setString("string", .{ .table = string_table });

        // table library
        const table_lib = try Table.create(allocator);
        try table_lib.setString("insert", .{ .builtin = .table_insert });
        try table_lib.setString("remove", .{ .builtin = .table_remove });
        try table_lib.setString("sort", .{ .builtin = .table_sort });
        try table_lib.setString("concat", .{ .builtin = .table_concat });
        try table_lib.setString("move", .{ .builtin = .table_move });
        try table_lib.setString("pack", .{ .builtin = .table_pack });
        try table_lib.setString("unpack", .{ .builtin = .table_unpack });
        try table_lib.setString("create", .{ .builtin = .table_create });
        try default_env.setString("table", .{ .table = table_lib });

        // io library (native profile only)
        const io_table = try Table.create(allocator);
        try io_table.setString("open", .{ .builtin = .io_open });
        try io_table.setString("close", .{ .builtin = .io_close });
        try io_table.setString("read", .{ .builtin = .io_read });
        try io_table.setString("write", .{ .builtin = .io_write });
        try io_table.setString("lines", .{ .builtin = .io_lines });
        try io_table.setString("type", .{ .builtin = .io_type });
        try io_table.setString("flush", .{ .builtin = .io_flush });
        try io_table.setString("tmpfile", .{ .builtin = .io_tmpfile });
        try io_table.setString("input", .{ .builtin = .io_input });
        try io_table.setString("output", .{ .builtin = .io_output });
        try io_table.setString("popen", .{ .builtin = .io_popen });
        try default_env.setString("io", .{ .table = io_table });
        try vm.declare("_ENV", .{ .table = default_env });
        return vm;
    }

    fn pushScope(self: *Vm, varargs: []const Value, has_varargs: bool) !void {
        try self.scopes.append(self.allocator, .{
            .vars = std.StringHashMap(*Cell).init(self.allocator),
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
        const cell = try self.allocator.create(Cell);
        cell.* = .{ .value = value };
        try self.currentScope().vars.put(name, cell);
    }

    fn assignName(self: *Vm, name: []const u8, value: Value) !void {
        if (self.activeFrame()) |frame| {
            if (self.assignNameInScopeRange(name, value, self.scopes.items.len, frame.scope_start)) return;
            if (frame.captures.get(name)) |cell| {
                cell.value = value;
                return;
            }
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
        const cell = try self.allocator.create(Cell);
        cell.* = .{ .value = value };
        try self.scopes.items[0].vars.put(name, cell);
    }

    fn lookup(self: *Vm, name: []const u8) Value {
        return self.lookupDetailed(name).value;
    }

    fn lookupDetailed(self: *Vm, name: []const u8) struct { value: Value, scope: ValueScope } {
        if (self.activeFrame()) |frame| {
            if (self.lookupNameInScopeRange(name, self.scopes.items.len, frame.scope_start)) |value| return .{ .value = value, .scope = .local };
            if (frame.captures.get(name)) |cell| return .{ .value = cell.value, .scope = .local };
            if (self.environmentForFrame(frame)) |env| {
                const value = env.getString(name);
                if (!value.isNil()) return .{ .value = value, .scope = .global };
            }
        } else {
            if (self.lookupNameInScopeRange(name, self.scopes.items.len, 0)) |value| return .{ .value = value, .scope = .local };
            if (self.currentEnvironment()) |env| {
                const value = env.getString(name);
                if (!value.isNil()) return .{ .value = value, .scope = .global };
            }
        }
        return .{ .value = .{ .nil = {} }, .scope = .global };
    }

    fn lookupNameInScopeRange(self: *Vm, name: []const u8, start_exclusive: usize, lower_inclusive: usize) ?Value {
        if (start_exclusive == 0 or lower_inclusive >= self.scopes.items.len) return null;
        var i = @min(start_exclusive, self.scopes.items.len);
        while (i > lower_inclusive) {
            i -= 1;
            if (self.scopes.items[i].vars.get(name)) |cell| return cell.value;
        }
        return null;
    }

    fn assignNameInScopeRange(self: *Vm, name: []const u8, value: Value, start_exclusive: usize, lower_inclusive: usize) bool {
        if (start_exclusive == 0 or lower_inclusive >= self.scopes.items.len) return false;
        var i = @min(start_exclusive, self.scopes.items.len);
        while (i > lower_inclusive) {
            i -= 1;
            if (self.scopes.items[i].vars.getPtr(name)) |slot| {
                slot.*.value = value;
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
                if (env.value == .table) return env.value.table;
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
        if (frame.captures.get("_ENV")) |env| {
            if (env.value == .table) return env.value.table;
        }
        if (frame.env) |env| return env;
        return self.environmentInScopeRange(@min(frame.lexical_scope_len, self.scopes.items.len), 0);
    }

    fn captureEnvironmentForDefinition(self: *Vm) ?*Table {
        if (self.activeFrame()) |frame| return self.environmentForFrame(frame);
        return self.currentEnvironment();
    }

    fn captureVisibleCells(self: *Vm) !std.StringHashMap(*Cell) {
        var captures = std.StringHashMap(*Cell).init(self.allocator);
        if (self.activeFrame()) |frame| {
            var captured = frame.captures.iterator();
            while (captured.next()) |entry| {
                try captures.put(entry.key_ptr.*, entry.value_ptr.*);
            }
            var i = frame.scope_start;
            while (i < self.scopes.items.len) : (i += 1) {
                var scoped = self.scopes.items[i].vars.iterator();
                while (scoped.next()) |entry| {
                    try captures.put(entry.key_ptr.*, entry.value_ptr.*);
                }
            }
            return captures;
        }

        for (self.scopes.items) |*scope| {
            var scoped = scope.vars.iterator();
            while (scoped.next()) |entry| {
                try captures.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
        return captures;
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
            .thread => try self.stdout.writer.writeAll("thread"),
            .wrapped_thread => try self.stdout.writer.writeAll("function"),
        }
    }

    fn setRuntimeError(self: *Vm, message: []const u8) void {
        self.runtime_error_message = message;
        self.runtime_error_value = .{ .string = message };
    }

    fn setRuntimeErrorAt(self: *Vm, line: usize, message: []const u8) void {
        self.runtime_error_line = line;
        self.runtime_error_message = message;
        self.runtime_error_value = .{ .string = message };
        self.runtime_error_metamethod = null;
    }

    fn setRuntimeErrorValueAt(self: *Vm, line: usize, value: Value, message: []const u8) void {
        self.runtime_error_line = line;
        self.runtime_error_message = message;
        self.runtime_error_value = value;
        self.runtime_error_metamethod = null;
    }

    fn setRuntimeMetamethodErrorAt(self: *Vm, line: usize, metamethod: []const u8, message: []const u8) void {
        self.runtime_error_line = line;
        self.runtime_error_message = message;
        self.runtime_error_value = .{ .string = message };
        self.runtime_error_metamethod = metamethod;
    }

    fn clearRuntimeError(self: *Vm) void {
        self.runtime_error_message = null;
        self.runtime_error_value = null;
        self.runtime_error_metamethod = null;
    }

    fn currentRuntimeErrorValue(self: *Vm) Value {
        if (self.runtime_error_value) |value| return value;
        if (self.runtime_error_message) |message| return .{ .string = message };
        return .{ .string = "runtime error" };
    }

    fn errorSourceLine(self: *Vm, line: usize) usize {
        if (line > self.error_line_offset) return line - self.error_line_offset;
        return line;
    }

    fn setSyntaxErrorAt(self: *Vm, line: usize, message: []const u8) void {
        self.syntax_error_line = line;
        self.syntax_error_message = message;
    }
};

const ValueScope = enum { unknown, local, global };

const Parser = struct {
    vm: *Vm,
    pos: usize,
    limit: usize,
    evaluate: bool,
    last_primary_name: ?[]const u8 = null,
    last_primary_scope: ValueScope = .unknown,
    last_call_values: ?[]const Value = null,
    active_call_line: ?usize = null,

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
        if (self.isCallStatementStart()) {
            const statement_start = self.pos;
            const continuation_depth = self.threadContinuationDepth();
            _ = self.expressionValues() catch |err| switch (err) {
                error.Yield => {
                    if (!self.isCoroutineYieldCallAt(statement_start) and self.threadContinuationDepth() > continuation_depth) {
                        try self.appendThreadContinuation(.{
                            .kind = .resume_body,
                            .local_name = null,
                            .local_names = &.{},
                            .assign_targets = &.{},
                            .prefix_values = &.{},
                            .pos = self.pos,
                            .body_end = self.limit,
                        });
                    }
                    return err;
                },
                else => return err,
            };
            return .normal;
        }
        if (self.peek().tag == .ident) return self.assignmentStatement();
        if (self.peek().tag == .eof) return .normal;
        return error.UnsupportedFeature;
    }

    fn threadContinuationDepth(self: *Parser) usize {
        if (self.vm.current_thread) |thread| return thread.continuations.items.len;
        return 0;
    }

    fn appendThreadContinuation(self: *Parser, continuation: CoroutineContinuation) !void {
        if (self.vm.current_thread) |thread| {
            try thread.continuations.append(thread.vm.allocator, continuation);
        }
    }

    fn discardAutoResumeContinuationAtCurrentPos(self: *Parser) void {
        if (self.vm.current_thread) |thread| {
            if (thread.continuations.items.len == 0) return;
            const index = thread.continuations.items.len - 1;
            const continuation = thread.continuations.items[index];
            if (continuation.kind == .resume_body and continuation.local_name == null and continuation.pos == self.pos) {
                _ = thread.continuations.orderedRemove(index);
            }
        }
    }

    fn isCallStatementStart(self: *Parser) bool {
        var p = self.scanPrimaryPrefix(self.pos) orelse return false;
        var saw_call = false;
        while (p < self.limit) {
            switch (self.tokens()[p].tag) {
                .dot => {
                    if (p + 1 >= self.limit or self.tokens()[p + 1].tag != .ident) return false;
                    p += 2;
                },
                .lbracket => {
                    p = self.skipBalancedWithinLimit(p, .lbracket, .rbracket) orelse return false;
                },
                .colon => {
                    if (p + 2 >= self.limit or self.tokens()[p + 1].tag != .ident or self.tokens()[p + 2].tag != .lparen) return false;
                    p = self.skipBalancedWithinLimit(p + 2, .lparen, .rparen) orelse return true;
                    saw_call = true;
                },
                .lparen => {
                    p = self.skipBalancedWithinLimit(p, .lparen, .rparen) orelse return true;
                    saw_call = true;
                },
                else => break,
            }
        }
        return saw_call and self.isCallStatementBoundary(p);
    }

    fn scanPrimaryPrefix(self: *Parser, start: usize) ?usize {
        if (start >= self.limit) return null;
        return switch (self.tokens()[start].tag) {
            .ident => start + 1,
            .lparen => self.skipBalancedWithinLimit(start, .lparen, .rparen),
            else => null,
        };
    }

    fn skipBalancedWithinLimit(self: *Parser, start: usize, open: TokenTag, close: TokenTag) ?usize {
        if (start >= self.limit or self.tokens()[start].tag != open) return null;
        const next = skipBalanced(self.tokens(), start, open, close);
        if (next > self.limit or next == 0) return null;
        if (self.tokens()[next - 1].tag != close) return null;
        return next;
    }

    fn isCallStatementBoundary(self: *Parser, pos: usize) bool {
        if (pos >= self.limit) return true;
        const token = self.tokens()[pos];
        return switch (token.tag) {
            .eof, .semi, .coloncolon, .ident, .lparen => true,
            .keyword => isStatementBoundaryKeyword(token) or std.mem.eql(u8, token.lexeme, "goto"),
            else => false,
        };
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
            if (names.items.len == 1 and self.isCoroutineYieldCallAt(self.pos)) {
                try self.parseCoroutineYieldCall();
                try self.appendThreadContinuation(.{
                    .kind = .resume_body,
                    .local_name = names.items[0],
                    .local_names = &.{},
                    .assign_targets = &.{},
                    .prefix_values = &.{},
                    .pos = self.pos,
                    .body_end = self.limit,
                });
                return error.Yield;
            }
            self.parseExpressionList(&values) catch |err| switch (err) {
                error.Yield => {
                    self.discardAutoResumeContinuationAtCurrentPos();
                    try self.appendThreadContinuation(.{
                        .kind = .pending_local_assignment,
                        .local_name = null,
                        .local_names = try names.toOwnedSlice(self.vm.allocator),
                        .assign_targets = &.{},
                        .prefix_values = try values.toOwnedSlice(self.vm.allocator),
                        .pos = self.pos,
                        .body_end = self.limit,
                    });
                    return err;
                },
                else => return err,
            };
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

    fn isCoroutineYieldCallAt(self: *Parser, start: usize) bool {
        return start + 4 < self.limit and
            self.tokens()[start].tag == .ident and std.mem.eql(u8, self.tokens()[start].lexeme, "coroutine") and
            self.tokens()[start + 1].tag == .dot and
            self.tokens()[start + 2].tag == .ident and std.mem.eql(u8, self.tokens()[start + 2].lexeme, "yield") and
            self.tokens()[start + 3].tag == .lparen;
    }

    fn parseCoroutineYieldCall(self: *Parser) !void {
        _ = try self.consumeIdent();
        try self.consume(.dot);
        const yield_name = try self.consumeIdent();
        if (!std.mem.eql(u8, yield_name, "yield")) return error.UnsupportedFeature;
        const open = self.peek();
        try self.consume(.lparen);
        var args: std.ArrayList(Value) = .empty;
        if (!self.match(.rparen)) {
            try self.parseExpressionList(&args);
            try self.consumeCloseParen(open.line);
        }
        if (self.vm.current_thread) |thread| {
            thread.yield_values = try args.toOwnedSlice(self.vm.allocator);
            return;
        }
        self.vm.setRuntimeErrorAt(open.line, "attempt to yield from outside a coroutine");
        return error.RuntimeError;
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
        const opener_line = self.tokens()[self.pos - 1].line;
        const name = try self.consumeIdent();
        if (self.vm.currentScope().vars.get(name) == null) {
            try self.vm.declare(name, .{ .nil = {} });
        }
        const function = try self.parseFunctionAfterName(name, opener_line);
        try self.vm.assignName(name, .{ .function = function });
        return .normal;
    }

    fn parseFunctionAfterName(self: *Parser, name: []const u8, opener_line: usize) !*Function {
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
        const body_end = try self.findEndFor(body_start, "function", opener_line);
        const function = try self.vm.allocator.create(Function);
        function.* = .{
            .name = name,
            .params = try params.toOwnedSlice(self.vm.allocator),
            .vararg = vararg,
            .body_start = body_start,
            .body_end = body_end,
            .env = self.vm.captureEnvironmentForDefinition(),
            .lexical_scope_len = self.vm.scopes.items.len,
            .captures = try self.vm.captureVisibleCells(),
        };
        self.pos = body_end + 1;
        return function;
    }

    fn parseAnonymousFunction(self: *Parser, opener_line: usize) !Value {
        const function = try self.parseFunctionAfterName("", opener_line);
        return .{ .function = function };
    }

    fn returnStatement(self: *Parser) !ExecSignal {
        var values: std.ArrayList(Value) = .empty;
        if (self.peekKeyword("end") or self.peek().tag == .eof) {
            return .{ .returned = &.{} };
        }
        self.parseExpressionList(&values) catch |err| switch (err) {
            error.Yield => {
                self.discardAutoResumeContinuationAtCurrentPos();
                try self.appendThreadContinuation(.{
                    .kind = .pending_return,
                    .local_name = null,
                    .local_names = &.{},
                    .assign_targets = &.{},
                    .prefix_values = try values.toOwnedSlice(self.vm.allocator),
                    .pos = self.pos,
                    .body_end = self.limit,
                });
                return err;
            },
            else => return err,
        };
        return .{ .returned = try values.toOwnedSlice(self.vm.allocator) };
    }

    fn doBlock(self: *Parser) !ExecSignal {
        const opener = self.tokens()[self.pos - 1];
        const end_idx = try self.findEndFor(self.pos, "do", opener.line);
        try self.vm.pushScope(&.{}, false);
        var body = Parser{ .vm = self.vm, .pos = self.pos, .limit = end_idx, .evaluate = self.evaluate };
        const signal = try body.parseBlock();
        self.vm.popScope();
        self.pos = end_idx + 1;
        return signal;
    }

    fn ifStatement(self: *Parser) !ExecSignal {
        const cond_start = self.pos;
        const opener = self.tokens()[cond_start - 1];
        const then_idx = try self.findKeywordAtDepth(cond_start, self.limit, "then");
        const end_idx = try self.findEndFor(then_idx + 1, "if", opener.line);
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
        const opener = self.tokens()[cond_start - 1];
        const do_idx = try self.findKeywordAtDepth(cond_start, self.limit, "do");
        const body_start = do_idx + 1;
        const end_idx = try self.findEndFor(body_start, "while", opener.line);
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
        const opener = self.tokens()[self.pos - 1];
        const name = try self.consumeIdent();
        if (!self.match(.assign)) return self.genericForStatement(name, opener.line);
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
        const end_idx = try self.findEndFor(body_start, "for", opener.line);
        try self.vm.pushScope(&.{}, false);
        defer self.vm.popScope();
        var i = start;
        var guard: usize = 0;
        while ((step >= 0 and i <= stop) or (step < 0 and i >= stop)) : (i += step) {
            guard += 1;
            if (guard > 100000) return error.UnsupportedFeature;
            const signal = blk: {
                try self.vm.pushScope(&.{}, false);
                errdefer self.vm.popScope();
                try self.vm.declare(name, numberFromFloatIntegral(i));
                var body = Parser{ .vm = self.vm, .pos = body_start, .limit = end_idx, .evaluate = self.evaluate };
                const body_signal = try body.parseBlock();
                self.vm.popScope();
                break :blk body_signal;
            };
            switch (signal) {
                .normal => {},
                .break_loop => break,
                .returned => return signal,
            }
        }
        self.pos = end_idx + 1;
        return .normal;
    }

    fn genericForStatement(self: *Parser, first_name: []const u8, opener_line: usize) !ExecSignal {
        var names: std.ArrayList([]const u8) = .empty;
        try names.append(self.vm.allocator, first_name);
        while (self.match(.comma)) {
            try names.append(self.vm.allocator, try self.consumeIdent());
        }
        if (!self.matchKeyword("in")) return error.UnsupportedFeature;
        const do_idx = try self.findKeywordAtDepth(self.pos, self.limit, "do");
        var expr_parser = Parser{ .vm = self.vm, .pos = self.pos, .limit = do_idx, .evaluate = self.evaluate };
        var iterator_values: std.ArrayList(Value) = .empty;
        try expr_parser.parseExpressionList(&iterator_values);
        if (iterator_values.items.len == 0) return error.RuntimeError;
        const iterator = iterator_values.items[0];
        const state = if (iterator_values.items.len > 1) iterator_values.items[1] else Value{ .nil = {} };
        var control = if (iterator_values.items.len > 2) iterator_values.items[2] else Value{ .nil = {} };

        const body_start = do_idx + 1;
        const end_idx = try self.findEndFor(body_start, "for", opener_line);
        try self.vm.pushScope(&.{}, false);
        defer self.vm.popScope();

        var guard: usize = 0;
        while (true) {
            guard += 1;
            if (guard > 100000) return error.UnsupportedFeature;
            const returns = try self.invokeCallable(iterator, &.{ state, control });
            if (returns.len == 0 or returns[0].isNil()) break;
            control = returns[0];

            const signal = blk: {
                try self.vm.pushScope(&.{}, false);
                errdefer self.vm.popScope();
                for (names.items, 0..) |loop_name, i| {
                    try self.vm.declare(loop_name, if (i < returns.len) returns[i] else Value{ .nil = {} });
                }
                var body = Parser{ .vm = self.vm, .pos = body_start, .limit = end_idx, .evaluate = self.evaluate };
                const body_signal = try body.parseBlock();
                self.vm.popScope();
                break :blk body_signal;
            };
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
        self.parseExpressionList(&values) catch |err| switch (err) {
            error.Yield => {
                self.discardAutoResumeContinuationAtCurrentPos();
                try self.appendThreadContinuation(.{
                    .kind = .pending_assignment,
                    .local_name = null,
                    .local_names = &.{},
                    .assign_targets = try targets.toOwnedSlice(self.vm.allocator),
                    .prefix_values = try values.toOwnedSlice(self.vm.allocator),
                    .pos = self.pos,
                    .body_end = self.limit,
                });
                return err;
            },
            else => return err,
        };
        for (targets.items, 0..) |target, i| {
            const value = if (i < values.items.len) values.items[i] else Value{ .nil = {} };
            switch (target.kind) {
                .name => try self.vm.assignName(target.name, value),
                .string_field => try self.setTableValue(target.table.?, .{ .string = target.key_string }, value, self.peek().line),
                .index => try self.setTableValue(target.table.?, target.key_value, value, self.peek().line),
            }
        }
        return .normal;
    }

    fn parseAssignTarget(self: *Parser) !AssignTarget {
        const name_token = self.peek();
        const name = try self.consumeIdent();
        if (self.match(.dot)) {
            const key_token = self.peek();
            const key = try self.consumeIdent();
            const table = switch (self.vm.lookup(name)) {
                .table => |t| t,
                else => |value| {
                    self.vm.setRuntimeErrorAt(
                        key_token.line,
                        try valueAccessErrorMessage(self.vm.allocator, "index", value, name, .local),
                    );
                    return error.RuntimeError;
                },
            };
            return .{ .kind = .string_field, .name = name, .table = table, .key_string = key, .key_value = .{ .string = key } };
        }
        if (self.match(.lbracket)) {
            const key = try self.expression(0);
            try self.consumeCloseBracket(name_token.line);
            const table = switch (self.vm.lookup(name)) {
                .table => |t| t,
                else => |value| {
                    self.vm.setRuntimeErrorAt(
                        name_token.line,
                        try valueAccessErrorMessage(self.vm.allocator, "index", value, name, .local),
                    );
                    return error.RuntimeError;
                },
            };
            return .{ .kind = .index, .name = name, .table = table, .key_value = key };
        }
        return .{ .kind = .name, .name = name };
    }

    fn parseExpressionList(self: *Parser, out: *std.ArrayList(Value)) !void {
        while (true) {
            self.last_call_values = null;
            const first_value = try self.expression(0);
            if (self.match(.comma)) {
                try out.append(self.vm.allocator, first_value);
                continue;
            }
            if (self.last_call_values) |values| {
                try out.appendSlice(self.vm.allocator, values);
            } else {
                try out.append(self.vm.allocator, first_value);
            }
            break;
        }
    }

    fn expressionValues(self: *Parser) anyerror![]const Value {
        if (self.match(.ellipsis)) return self.vm.currentVarargs();
        self.last_call_values = null;
        const value = try self.expression(0);
        if (self.last_call_values) |values| return values;
        const values = try self.vm.allocator.alloc(Value, 1);
        values[0] = value;
        return values;
    }

    fn expression(self: *Parser, min_prec: u8) anyerror!Value {
        const left = self.prefix() catch |err| switch (err) {
            error.Yield => {
                const op = self.peek();
                const prec = binaryPrecedence(op);
                if (prec != 0 and prec >= min_prec) {
                    self.discardAutoResumeContinuationAtCurrentPos();
                    try self.appendThreadContinuation(.{
                        .kind = .pending_expression,
                        .local_name = null,
                        .local_names = &.{},
                        .assign_targets = &.{},
                        .prefix_values = &.{},
                        .pos = self.pos,
                        .body_end = self.limit,
                        .expression_min_prec = min_prec,
                    });
                }
                return err;
            },
            else => return err,
        };
        return self.continueExpression(left, min_prec);
    }

    fn continueExpression(self: *Parser, initial_left: Value, min_prec: u8) anyerror!Value {
        var left = initial_left;
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
                    left = self.expression(prec + 1) catch |err| switch (err) {
                        error.Yield => {
                            self.discardAutoResumeContinuationAtCurrentPos();
                            try self.appendThreadContinuation(.{
                                .kind = .pending_binary,
                                .local_name = null,
                                .local_names = &.{},
                                .assign_targets = &.{},
                                .prefix_values = &.{},
                                .pos = self.pos,
                                .body_end = self.limit,
                                .expression_min_prec = min_prec,
                                .binary_left = left,
                                .binary_op = op,
                            });
                            return err;
                        },
                        else => return err,
                    };
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
                    left = self.expression(prec + 1) catch |err| switch (err) {
                        error.Yield => {
                            self.discardAutoResumeContinuationAtCurrentPos();
                            try self.appendThreadContinuation(.{
                                .kind = .pending_binary,
                                .local_name = null,
                                .local_names = &.{},
                                .assign_targets = &.{},
                                .prefix_values = &.{},
                                .pos = self.pos,
                                .body_end = self.limit,
                                .expression_min_prec = min_prec,
                                .binary_left = left,
                                .binary_op = op,
                            });
                            return err;
                        },
                        else => return err,
                    };
                }
                continue;
            }
            const right_min = if (op.tag == .concat) prec else prec + 1;
            const right = self.expression(right_min) catch |err| switch (err) {
                error.Yield => {
                    self.discardAutoResumeContinuationAtCurrentPos();
                    try self.appendThreadContinuation(.{
                        .kind = .pending_binary,
                        .local_name = null,
                        .local_names = &.{},
                        .assign_targets = &.{},
                        .prefix_values = &.{},
                        .pos = self.pos,
                        .body_end = self.limit,
                        .expression_min_prec = min_prec,
                        .binary_left = left,
                        .binary_op = op,
                    });
                    return err;
                },
                else => return err,
            };
            if (!self.evaluate) {
                left = .{ .nil = {} };
                self.last_call_values = null;
                continue;
            }
            left = try self.applyBinaryValue(op, left, right);
            self.last_call_values = null;
        }
        return left;
    }

    fn applyResumedBinaryValue(self: *Parser, op: Token, left: Value, right: Value) anyerror!Value {
        if (op.tag == .keyword and std.mem.eql(u8, op.lexeme, "and")) return right;
        if (op.tag == .keyword and std.mem.eql(u8, op.lexeme, "or")) return right;
        return self.applyBinaryValue(op, left, right);
    }

    fn prefix(self: *Parser) anyerror!Value {
        if (self.match(.minus)) {
            const op = self.tokens()[self.pos - 1];
            const value = try self.expression(11);
            if (!self.evaluate) return .{ .nil = {} };
            self.last_call_values = null;
            return unaryMinus(self.vm, op.line, value);
        }
        if (self.match(.len)) {
            const op = self.tokens()[self.pos - 1];
            const value = try self.expression(11);
            if (!self.evaluate) return .{ .nil = {} };
            self.last_call_values = null;
            return self.lengthValue(op.line, value);
        }
        if (self.match(.tilde)) {
            const op = self.tokens()[self.pos - 1];
            const value = try self.expression(11);
            if (!self.evaluate) return .{ .nil = {} };
            self.last_call_values = null;
            return self.bitNotValue(op.line, value);
        }
        if (self.matchKeyword("not")) {
            const value = try self.expression(11);
            if (!self.evaluate) return .{ .nil = {} };
            self.last_call_values = null;
            return .{ .boolean = !value.isTruthy() };
        }
        return self.postfix(try self.primary());
    }

    fn postfix(self: *Parser, initial: Value) !Value {
        var value = initial;
        var context_name = self.last_primary_name;
        var context_scope = self.last_primary_scope;
        while (true) {
            if (self.match(.dot)) {
                self.last_call_values = null;
                const key_token = self.peek();
                const key = try self.consumeIdent();
                value = switch (value) {
                    .table => |t| try self.getTableValue(t, .{ .string = key }, key_token.line),
                    else => {
                        self.vm.setRuntimeErrorAt(
                            key_token.line,
                            try valueAccessErrorMessage(self.vm.allocator, "index", value, context_name, context_scope),
                        );
                        return error.RuntimeError;
                    },
                };
                context_name = null;
                context_scope = .unknown;
            } else if (self.match(.colon)) {
                self.last_call_values = null;
                const key_token = self.peek();
                const key = try self.consumeIdent();
                const receiver = value;
                value = switch (value) {
                    .table => |t| try self.getTableValue(t, .{ .string = key }, key_token.line),
                    else => {
                        self.vm.setRuntimeErrorAt(
                            key_token.line,
                            try valueAccessErrorMessage(self.vm.allocator, "index", value, context_name, context_scope),
                        );
                        return error.RuntimeError;
                    },
                };
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
                    self.last_call_values = null;
                    continue;
                }
                const continuation_depth = self.threadContinuationDepth();
                const returns = self.callFunctionValueWithPrefix(value, receiver) catch |err| {
                    if (err == error.Yield and self.threadContinuationDepth() == continuation_depth) {
                        try self.appendThreadContinuation(.{
                            .kind = .resume_body,
                            .local_name = null,
                            .local_names = &.{},
                            .assign_targets = &.{},
                            .prefix_values = &.{},
                            .pos = self.pos,
                            .body_end = self.limit,
                        });
                    }
                    return err;
                };
                self.last_call_values = returns;
                value = if (returns.len == 0) Value{ .nil = {} } else returns[0];
                context_name = null;
                context_scope = .unknown;
            } else if (self.match(.lbracket)) {
                self.last_call_values = null;
                const bracket_line = self.tokens()[self.pos - 1].line;
                const key = try self.expression(0);
                try self.consumeCloseBracket(bracket_line);
                value = switch (value) {
                    .table => |t| try self.getTableValue(t, key, bracket_line),
                    else => {
                        self.vm.setRuntimeErrorAt(
                            bracket_line,
                            try valueAccessErrorMessage(self.vm.allocator, "index", value, context_name, context_scope),
                        );
                        return error.RuntimeError;
                    },
                };
                context_name = null;
                context_scope = .unknown;
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
                    self.last_call_values = null;
                    continue;
                }
                const call_line = self.peek().line;
                const continuation_depth = self.threadContinuationDepth();
                const returns = self.callFunctionValue(value) catch |err| {
                    if (err == error.Yield) {
                        if (self.threadContinuationDepth() == continuation_depth) {
                            try self.appendThreadContinuation(.{
                                .kind = .resume_body,
                                .local_name = null,
                                .local_names = &.{},
                                .assign_targets = &.{},
                                .prefix_values = &.{},
                                .pos = self.pos,
                                .body_end = self.limit,
                            });
                        }
                        return err;
                    }
                    if (err == error.RuntimeError and value != .function and value != .builtin) {
                        self.vm.setRuntimeErrorAt(
                            call_line,
                            try valueAccessErrorMessage(self.vm.allocator, "call", value, context_name, context_scope),
                        );
                    }
                    return err;
                };
                self.last_call_values = returns;
                value = if (returns.len == 0) Value{ .nil = {} } else returns[0];
                context_name = null;
                context_scope = .unknown;
            } else break;
        }
        return value;
    }

    fn getTableValue(self: *Parser, table: *Table, key: Value, line: usize) anyerror!Value {
        const raw = try table.rawGetKey(key);
        if (!raw.isNil()) return raw;
        const metamethod = table.rawMetafield("__index");
        if (metamethod.isNil()) return raw;
        switch (metamethod) {
            .table => |mt| return self.getTableValue(mt, key, line),
            .function, .builtin => {
                const returns = try self.invokeCallable(metamethod, &.{ .{ .table = table }, key });
                return if (returns.len == 0) Value{ .nil = {} } else returns[0];
            },
            else => return raw,
        }
    }

    fn setTableValue(self: *Parser, table: *Table, key: Value, value: Value, line: usize) anyerror!void {
        const current = try table.rawGetKey(key);
        if (!current.isNil()) {
            try self.rawSetTableValue(table, key, value, line);
            return;
        }
        const metamethod = table.rawMetafield("__newindex");
        if (metamethod.isNil()) {
            try self.rawSetTableValue(table, key, value, line);
            return;
        }
        switch (metamethod) {
            .table => |mt| try self.setTableValue(mt, key, value, line),
            .function, .builtin => {
                _ = try self.invokeCallable(metamethod, &.{ .{ .table = table }, key, value });
            },
            else => try self.rawSetTableValue(table, key, value, line),
        }
    }

    fn rawSetTableValue(self: *Parser, table: *Table, key: Value, value: Value, line: usize) anyerror!void {
        table.rawSetKey(self.vm.allocator, key, value) catch |err| switch (err) {
            error.RuntimeError => {
                self.vm.setRuntimeErrorAt(line, tableIndexErrorMessage(key));
                return error.RuntimeError;
            },
            else => return err,
        };
    }

    fn valueMetafield(_: *Parser, value: Value, name: []const u8) Value {
        return switch (value) {
            .table => |t| t.rawMetafield(name),
            else => .{ .nil = {} },
        };
    }

    fn invokeMetamethod(self: *Parser, metamethod: Value, args: []const Value) anyerror!Value {
        switch (metamethod) {
            .function, .builtin => {
                const returns = try self.invokeCallable(metamethod, args);
                return if (returns.len == 0) Value{ .nil = {} } else returns[0];
            },
            else => return error.RuntimeError,
        }
    }

    fn writePrintValue(self: *Parser, value: Value) anyerror!void {
        if (value == .table) {
            const mm = value.table.rawMetafield("__tostring");
            if (!mm.isNil()) {
                const text_value = try self.invokeMetamethod(mm, &.{value});
                return self.vm.writeValue(text_value);
            }
        }
        try self.vm.writeValue(value);
    }

    fn binaryMetamethod(self: *Parser, left: Value, right: Value, name: []const u8) Value {
        const left_mm = self.valueMetafield(left, name);
        if (!left_mm.isNil()) return left_mm;
        return self.valueMetafield(right, name);
    }

    fn applyBinaryValue(self: *Parser, op: Token, left: Value, right: Value) anyerror!Value {
        const meta_name = binaryMetamethodName(op.tag);
        if (meta_name) |name| {
            if (!binaryOperandsAreRawSupported(op.tag, left, right)) {
                const mm = self.binaryMetamethod(left, right, name);
                if (!mm.isNil()) return self.invokeMetamethod(mm, &.{ left, right });
            }
        }
        if (op.tag == .eq or op.tag == .ne) {
            const raw_equal = valuesEqual(left, right);
            if (raw_equal) {
                return .{ .boolean = op.tag == .eq };
            }
            if (std.meta.activeTag(left) == std.meta.activeTag(right)) {
                const mm = self.binaryMetamethod(left, right, "__eq");
                if (!mm.isNil()) {
                    const result = try self.invokeMetamethod(mm, &.{ left, right });
                    return .{ .boolean = if (op.tag == .eq) result.isTruthy() else !result.isTruthy() };
                }
            }
        }
        if ((op.tag == .lt or op.tag == .gt) and !binaryOperandsAreRawSupported(op.tag, left, right)) {
            const mm = self.binaryMetamethod(left, right, "__lt");
            if (!mm.isNil()) {
                const result = if (op.tag == .lt)
                    try self.invokeMetamethod(mm, &.{ left, right })
                else
                    try self.invokeMetamethod(mm, &.{ right, left });
                return .{ .boolean = result.isTruthy() };
            }
        }
        if ((op.tag == .le or op.tag == .ge) and !binaryOperandsAreRawSupported(op.tag, left, right)) {
            const mm = self.binaryMetamethod(left, right, "__le");
            if (!mm.isNil()) {
                const result = if (op.tag == .le)
                    try self.invokeMetamethod(mm, &.{ left, right })
                else
                    try self.invokeMetamethod(mm, &.{ right, left });
                return .{ .boolean = result.isTruthy() };
            }
            const lt = self.binaryMetamethod(left, right, "__lt");
            if (!lt.isNil()) {
                const result = if (op.tag == .le)
                    try self.invokeMetamethod(lt, &.{ right, left })
                else
                    try self.invokeMetamethod(lt, &.{ left, right });
                return .{ .boolean = !result.isTruthy() };
            }
        }
        return applyBinary(self.vm, op, left, right);
    }

    fn lengthValue(self: *Parser, line: usize, value: Value) anyerror!Value {
        if (value == .table) {
            const mm = value.table.rawMetafield("__len");
            if (!mm.isNil()) return self.invokeMetamethod(mm, &.{value});
        }
        return lengthValueRaw(self.vm, line, value);
    }

    fn bitNotValue(self: *Parser, line: usize, value: Value) anyerror!Value {
        if (valueToInteger(value)) |i| return .{ .integer = ~i } else |_| {
            const mm = self.valueMetafield(value, "__bnot");
            if (!mm.isNil()) return self.invokeMetamethod(mm, &.{value});
            self.vm.setRuntimeErrorAt(line, try bitwiseErrorMessage(self.vm.allocator, value));
            return error.RuntimeError;
        }
    }

    fn callFunctionValue(self: *Parser, callee: Value) anyerror![]const Value {
        const open = self.peek();
        try self.consume(.lparen);
        var args: std.ArrayList(Value) = .empty;
        if (!self.match(.rparen)) {
            self.parseExpressionList(&args) catch |err| switch (err) {
                error.Yield => {
                    self.discardAutoResumeContinuationAtCurrentPos();
                    try self.appendThreadContinuation(.{
                        .kind = .pending_call,
                        .local_name = null,
                        .local_names = &.{},
                        .assign_targets = &.{},
                        .prefix_values = try args.toOwnedSlice(self.vm.allocator),
                        .pos = self.pos,
                        .body_end = self.limit,
                        .call_callee = callee,
                        .call_open_line = open.line,
                        .call_prepend_callee = true,
                    });
                    return err;
                },
                else => return err,
            };
            try self.consumeCloseParen(open.line);
        }
        return self.invokePreparedCall(callee, args.items, open.line, true);
    }

    fn callFunctionValueWithPrefix(self: *Parser, callee: Value, receiver: Value) anyerror![]const Value {
        const open = self.peek();
        try self.consume(.lparen);
        var args: std.ArrayList(Value) = .empty;
        try args.append(self.vm.allocator, receiver);
        if (!self.match(.rparen)) {
            self.parseExpressionList(&args) catch |err| switch (err) {
                error.Yield => {
                    self.discardAutoResumeContinuationAtCurrentPos();
                    try self.appendThreadContinuation(.{
                        .kind = .pending_call,
                        .local_name = null,
                        .local_names = &.{},
                        .assign_targets = &.{},
                        .prefix_values = try args.toOwnedSlice(self.vm.allocator),
                        .pos = self.pos,
                        .body_end = self.limit,
                        .call_callee = callee,
                        .call_open_line = open.line,
                        .call_prepend_callee = false,
                    });
                    return err;
                },
                else => return err,
            };
            try self.consumeCloseParen(open.line);
        }
        return self.invokePreparedCall(callee, args.items, open.line, false);
    }

    fn invokePreparedCall(self: *Parser, callee: Value, args: []const Value, open_line: usize, prepend_callee_for_call_metamethod: bool) anyerror![]const Value {
        if (callee == .table) {
            const metamethod = callee.table.rawMetafield("__call");
            if (metamethod == .function or metamethod == .builtin) {
                var call_args: std.ArrayList(Value) = .empty;
                if (prepend_callee_for_call_metamethod) try call_args.append(self.vm.allocator, callee);
                try call_args.appendSlice(self.vm.allocator, args);
                const previous_call_line = self.active_call_line;
                self.active_call_line = open_line;
                defer self.active_call_line = previous_call_line;
                return self.invokeCallable(metamethod, call_args.items);
            }
        }
        if (callee != .function and callee != .builtin and callee != .wrapped_thread) {
            self.vm.setRuntimeErrorAt(open_line, try std.fmt.allocPrint(self.vm.allocator, "attempt to call a {s} value", .{valueTypeName(callee)}));
            return error.RuntimeError;
        }
        const previous_call_line = self.active_call_line;
        self.active_call_line = open_line;
        defer self.active_call_line = previous_call_line;
        return self.invokeCallable(callee, args);
    }

    fn invokeCallable(self: *Parser, callee: Value, args: []const Value) anyerror![]const Value {
        const function = switch (callee) {
            .function => |f| f,
            .builtin => |b| return self.executeBuiltin(b, args),
            .wrapped_thread => |t| return self.callWrappedThread(t, args),
            else => {
                if (self.vm.runtime_error_message == null) {
                    self.vm.setRuntimeErrorAt(
                        self.peek().line,
                        try std.fmt.allocPrint(self.vm.allocator, "attempt to call a {s} value", .{valueTypeName(callee)}),
                    );
                }
                return error.RuntimeError;
            },
        };
        return self.executeFunction(function, args);
    }

    fn executeBuiltin(self: *Parser, builtin: Builtin, args: []const Value) anyerror![]const Value {
        switch (builtin) {
            .print => {
                for (args, 0..) |value, i| {
                    if (i != 0) try self.vm.stdout.writer.writeAll("\t");
                    try self.writePrintValue(value);
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
            .pairs => {
                if (args.len == 0 or args[0] != .table) return error.RuntimeError;
                const values = try self.vm.allocator.alloc(Value, 3);
                values[0] = .{ .builtin = .next };
                values[1] = args[0];
                values[2] = .{ .nil = {} };
                return values;
            },
            .ipairs => {
                if (args.len == 0 or args[0] != .table) return error.RuntimeError;
                const values = try self.vm.allocator.alloc(Value, 3);
                values[0] = .{ .builtin = .ipairs_iter };
                values[1] = args[0];
                values[2] = .{ .integer = 0 };
                return values;
            },
            .next => return self.nextTable(args),
            .ipairs_iter => return self.ipairsIter(args),
            .rawget => {
                if (args.len < 2 or args[0] != .table) return error.RuntimeError;
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = try args[0].table.rawGetKey(args[1]);
                return values;
            },
            .rawset => {
                if (args.len < 3 or args[0] != .table) return error.RuntimeError;
                try self.rawSetTableValue(args[0].table, args[1], args[2], self.peek().line);
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = args[0];
                return values;
            },
            .rawequal => {
                if (args.len < 2) return error.RuntimeError;
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .boolean = valuesEqual(args[0], args[1]) };
                return values;
            },
            .rawlen => {
                if (args.len < 1) return error.RuntimeError;
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = switch (args[0]) {
                    .table => |t| .{ .integer = t.length() },
                    .string => |s| .{ .integer = @intCast(s.len) },
                    else => return error.RuntimeError,
                };
                return values;
            },
            .setmetatable => {
                if (args.len < 2 or args[0] != .table) return error.RuntimeError;
                if (!args[0].table.rawMetafield("__metatable").isNil()) {
                    self.vm.setRuntimeErrorAt(self.active_call_line orelse self.peek().line, "cannot change a protected metatable");
                    return error.RuntimeError;
                }
                args[0].table.metatable = switch (args[1]) {
                    .nil => null,
                    .table => |t| t,
                    else => return error.RuntimeError,
                };
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = args[0];
                return values;
            },
            .getmetatable => {
                if (args.len < 1) return error.RuntimeError;
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = switch (args[0]) {
                    .table => |t| blk: {
                        const protected = t.rawMetafield("__metatable");
                        if (!protected.isNil()) break :blk protected;
                        break :blk if (t.metatable) |mt| .{ .table = mt } else .{ .nil = {} };
                    },
                    else => .{ .nil = {} },
                };
                return values;
            },
            .tostring => {
                if (args.len < 1) return error.RuntimeError;
                const values = try self.vm.allocator.alloc(Value, 1);
                if (args[0] == .table and !args[0].table.rawMetafield("__tostring").isNil()) {
                    values[0] = try self.invokeMetamethod(args[0].table.rawMetafield("__tostring"), &.{args[0]});
                } else {
                    values[0] = .{ .string = try valueToStringForTostring(self.vm.allocator, args[0]) };
                }
                return values;
            },
            .type => {
                if (args.len < 1) return error.RuntimeError;
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .string = valueTypeName(args[0]) };
                return values;
            },
            .lua_error => {
                const raw_value = if (args.len > 0) args[0] else Value{ .nil = {} };
                const error_value = if (raw_value.isNil()) Value{ .string = "<no error object>" } else raw_value;
                const level = if (args.len > 1 and !args[1].isNil()) try valueToInteger(args[1]) else 1;
                const raw_line = self.active_call_line orelse self.peek().line;
                const final_value = if (error_value == .string and level > 0) blk: {
                    const source_line = self.errorLevelLine(level) orelse break :blk error_value;
                    break :blk Value{ .string = try std.fmt.allocPrint(
                        self.vm.allocator,
                        "{s}:{d}: {s}",
                        .{ self.vm.error_chunk_name, self.vm.errorSourceLine(source_line), error_value.string },
                    ) };
                } else error_value;
                const message = try valueToStringForTostring(self.vm.allocator, final_value);
                self.vm.setRuntimeErrorValueAt(raw_line, final_value, message);
                return error.RuntimeError;
            },
            .pcall => {
                if (args.len < 1) return error.RuntimeError;
                return self.protectedCall(args[0], args[1..], null);
            },
            .xpcall => {
                if (args.len < 2) return error.RuntimeError;
                return self.protectedCall(args[0], args[2..], args[1]);
            },
            .coroutine_create => {
                if (args.len < 1 or args[0] != .function) return error.RuntimeError;
                const thread = try self.vm.allocator.create(Thread);
                thread.* = .{
                    .vm = try Vm.initWithContext(self.vm.allocator, self.vm.tokens, &.{}, self.vm.error_chunk_name, self.vm.error_line_offset),
                    .function = args[0].function,
                    .status = .suspended,
                    .continuations = .empty,
                    .yield_values = &.{},
                    .close_error = null,
                };
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .thread = thread };
                return values;
            },
            .coroutine_resume => {
                if (args.len < 1 or args[0] != .thread) return error.RuntimeError;
                return self.resumeThread(args[0].thread, args[1..]);
            },
            .coroutine_yield => {
                if (self.vm.current_thread) |thread| {
                    thread.yield_values = try self.vm.allocator.dupe(Value, args);
                    return error.Yield;
                }
                self.vm.setRuntimeErrorAt(self.active_call_line orelse self.peek().line, "attempt to yield from outside a coroutine");
                return error.RuntimeError;
            },
            .coroutine_status => {
                if (args.len < 1 or args[0] != .thread) return error.RuntimeError;
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .string = switch (args[0].thread.status) {
                    .suspended => "suspended",
                    .running => "running",
                    .normal => "normal",
                    .dead => "dead",
                } };
                return values;
            },
            .coroutine_close => {
                const target = if (args.len == 0) blk: {
                    if (self.vm.current_thread) |thread| break :blk thread;
                    self.vm.setRuntimeErrorAt(self.active_call_line orelse self.peek().line, "cannot close main thread");
                    return error.RuntimeError;
                } else blk: {
                    if (args[0] != .thread) {
                        self.vm.setRuntimeErrorAt(
                            self.active_call_line orelse self.peek().line,
                            try std.fmt.allocPrint(
                                self.vm.allocator,
                                "bad argument #1 to 'close' (thread expected, got {s})",
                                .{valueTypeName(args[0])},
                            ),
                        );
                        return error.RuntimeError;
                    }
                    break :blk args[0].thread;
                };
                return self.closeThread(target);
            },
            .coroutine_wrap => {
                if (args.len < 1 or args[0] != .function) return error.RuntimeError;
                const thread = try self.vm.allocator.create(Thread);
                thread.* = .{
                    .vm = try Vm.initWithContext(self.vm.allocator, self.vm.tokens, &.{}, self.vm.error_chunk_name, self.vm.error_line_offset),
                    .function = args[0].function,
                    .status = .suspended,
                    .continuations = .empty,
                    .yield_values = &.{},
                    .close_error = null,
                };
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .wrapped_thread = thread };
                return values;
            },
            .coroutine_running => {
                const values = try self.vm.allocator.alloc(Value, 2);
                if (self.vm.current_thread) |thread| {
                    values[0] = .{ .thread = thread };
                    values[1] = .{ .boolean = false };
                } else {
                    values[0] = .{ .nil = {} };
                    values[1] = .{ .boolean = true };
                }
                return values;
            },
            .coroutine_isyieldable => {
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .boolean = self.vm.current_thread != null };
                return values;
            },

            // ====================
            // math library
            // ====================

            .math_abs => {
                if (args.len == 0) return error.RuntimeError;
                const n = try self.toNumber(args[0]);
                const result: Value = switch (n) {
                    .integer => |i| .{ .integer = if (i == std.math.minInt(i64)) blk: {
                        break :blk @as(i64, @intFromFloat(@abs(@as(f64, @floatFromInt(i)))));
                    } else if (i < 0) -i else i },
                    .float => |f| if (f != f) .{ .float = std.math.nan(f64) } else .{ .float = @abs(f) },
                    else => return error.RuntimeError,
                };
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = result;
                return values;
            },
            .math_ceil => {
                if (args.len == 0) return error.RuntimeError;
                const n = try self.toNumber(args[0]);
                const values = try self.vm.allocator.alloc(Value, 1);
                switch (n) {
                    .integer => |i| values[0] = .{ .integer = i },
                    .float => |f| {
                        const result = std.math.ceil(f);
                        if (floatToInteger(result, .eq)) |i| {
                            values[0] = .{ .integer = i };
                        } else {
                            values[0] = .{ .float = result };
                        }
                    },
                    else => return error.RuntimeError,
                }
                return values;
            },
            .math_floor => {
                if (args.len == 0) return error.RuntimeError;
                const n = try self.toNumber(args[0]);
                const values = try self.vm.allocator.alloc(Value, 1);
                switch (n) {
                    .integer => |i| values[0] = .{ .integer = i },
                    .float => |f| {
                        const result = std.math.floor(f);
                        if (floatToInteger(result, .eq)) |i| {
                            values[0] = .{ .integer = i };
                        } else {
                            values[0] = .{ .float = result };
                        }
                    },
                    else => return error.RuntimeError,
                }
                return values;
            },
            .math_sqrt => {
                if (args.len == 0) return error.RuntimeError;
                const n = try self.toNumber(args[0]);
                const f = switch (n) {
                    .integer => |i| @as(f64, @floatFromInt(i)),
                    .float => |f2| f2,
                    else => return error.RuntimeError,
                };
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .float = @sqrt(f) };
                return values;
            },
            .math_max => {
                if (args.len == 0) return error.RuntimeError;
                var best = try self.toNumber(args[0]);
                for (args[1..]) |arg| {
                    const n = try self.toNumber(arg);
                    if (compareNumbers(n, best, .gt)) best = n;
                }
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = numberToValue(best);
                return values;
            },
            .math_min => {
                if (args.len == 0) return error.RuntimeError;
                var best = try self.toNumber(args[0]);
                for (args[1..]) |arg| {
                    const n = try self.toNumber(arg);
                    if (compareNumbers(n, best, .lt)) best = n;
                }
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = numberToValue(best);
                return values;
            },
            .math_exp => {
                if (args.len == 0) return error.RuntimeError;
                const n = try self.toNumber(args[0]);
                const f = switch (n) {
                    .integer => |i| @as(f64, @floatFromInt(i)),
                    .float => |f2| f2,
                    else => return error.RuntimeError,
                };
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .float = @exp(f) };
                return values;
            },
            .math_log => {
                if (args.len == 0) return error.RuntimeError;
                const n = try self.toNumber(args[0]);
                const x = switch (n) {
                    .integer => |i| @as(f64, @floatFromInt(i)),
                    .float => |f2| f2,
                    else => return error.RuntimeError,
                };
                const result = if (args.len >= 2) blk: {
                    const base_n = try self.toNumber(args[1]);
                    const base = switch (base_n) {
                        .integer => |i| @as(f64, @floatFromInt(i)),
                        .float => |f2| f2,
                        else => return error.RuntimeError,
                    };
                    break :blk @log(x) / @log(base);
                } else @log(x);
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .float = result };
                return values;
            },
            .math_sin => return self.mathTrig(args, std.math.sin),
            .math_cos => return self.mathTrig(args, std.math.cos),
            .math_tan => return self.mathTrig(args, std.math.tan),
            .math_asin => return self.mathTrig(args, std.math.asin),
            .math_acos => return self.mathTrig(args, std.math.acos),
            .math_atan => {
                if (args.len == 0) return error.RuntimeError;
                const n = try self.toNumber(args[0]);
                const y = switch (n) {
                    .integer => |i| @as(f64, @floatFromInt(i)),
                    .float => |f2| f2,
                    else => return error.RuntimeError,
                };
                const result = if (args.len >= 2) blk: {
                    const xn = try self.toNumber(args[1]);
                    const x = switch (xn) {
                        .integer => |i| @as(f64, @floatFromInt(i)),
                        .float => |f2| f2,
                        else => return error.RuntimeError,
                    };
                    break :blk std.math.atan2(y, x);
                } else std.math.atan(y);
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .float = result };
                return values;
            },
            .math_deg => {
                if (args.len == 0) return error.RuntimeError;
                const n = try self.toNumber(args[0]);
                const r = switch (n) {
                    .integer => |i| @as(f64, @floatFromInt(i)),
                    .float => |f2| f2,
                    else => return error.RuntimeError,
                };
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .float = r * 180.0 / std.math.pi };
                return values;
            },
            .math_rad => {
                if (args.len == 0) return error.RuntimeError;
                const n = try self.toNumber(args[0]);
                const d = switch (n) {
                    .integer => |i| @as(f64, @floatFromInt(i)),
                    .float => |f2| f2,
                    else => return error.RuntimeError,
                };
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .float = d * std.math.pi / 180.0 };
                return values;
            },
            .math_fmod => {
                if (args.len < 2) return error.RuntimeError;
                const a = try self.toFloat(args[0]);
                const b = try self.toFloat(args[1]);
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .float = @mod(a, b) };
                return values;
            },
            .math_modf => {
                if (args.len == 0) return error.RuntimeError;
                const f = try self.toFloat(args[0]);
                const frac = @mod(f, 1.0);
                const int_part = f - frac;
                const values = try self.vm.allocator.alloc(Value, 2);
                values[0] = .{ .float = if (frac == 0.0) 0.0 else frac };
                if (floatToInteger(int_part, .eq)) |i| {
                    values[1] = .{ .integer = i };
                } else {
                    values[1] = .{ .float = int_part };
                }
                return values;
            },
            .math_frexp => {
                if (args.len == 0) return error.RuntimeError;
                const f = try self.toFloat(args[0]);
                const result = std.math.frexp(f);
                const values = try self.vm.allocator.alloc(Value, 2);
                values[0] = .{ .float = result.significand };
                values[1] = .{ .integer = result.exponent };
                return values;
            },
            .math_ldexp => {
                if (args.len < 2) return error.RuntimeError;
                const f = try self.toFloat(args[0]);
                const e = try self.toInteger(args[1]);
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .float = std.math.ldexp(f, @intCast(e)) };
                return values;
            },
            .math_ult => {
                if (args.len < 2) return error.RuntimeError;
                const a = try self.toInteger(args[0]);
                const b = try self.toInteger(args[1]);
                const values = try self.vm.allocator.alloc(Value, 1);
                // Reinterpret as unsigned for comparison
                const ua: u64 = @bitCast(a);
                const ub: u64 = @bitCast(b);
                values[0] = .{ .boolean = ua < ub };
                return values;
            },
            .math_tointeger => {
                if (args.len == 0) return error.RuntimeError;
                const n = try self.toNumber(args[0]);
                const values = try self.vm.allocator.alloc(Value, 1);
                switch (n) {
                    .integer => |i| values[0] = .{ .integer = i },
                    .float => |f| values[0] = if (floatToInteger(f, .eq)) |i| .{ .integer = i } else .{ .nil = {} },
                    else => return error.RuntimeError,
                }
                return values;
            },
            .math_type => {
                if (args.len == 0) return error.RuntimeError;
                const n = try self.toNumber(args[0]);
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = switch (n) {
                    .integer => .{ .string = "integer" },
                    .float => .{ .string = "float" },
                    else => .{ .nil = {} },
                };
                return values;
            },
            .math_random => {
                // Simple LCG for now (not cryptographic quality)
                // Use a thread-local seed stored in the Parser/VM
                const lo: i64 = if (args.len >= 1) try self.toInteger(args[0]) else 1;
                const hi: i64 = if (args.len >= 2) try self.toInteger(args[1]) else if (args.len >= 1) std.math.maxInt(i64) else 1;
                const range = hi - lo + 1;
                // Simple pseudo-random from stack address hash
                var tmp: u64 = 0xDEADBEEF;
                var seed: u64 = @intFromPtr(&tmp);
                seed ^= seed >> 33;
                seed *%= 0xff51afd7ed558ccd;
                seed ^= seed >> 33;
                seed *%= 0xc4ceb9fe1a85ec53;
                seed ^= seed >> 33;
                const ur = if (range > 0) @abs(seed % @abs(range)) else @as(u64, 0);
                const r = lo + @as(i64, @intCast(ur));
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .integer = r };
                return values;
            },
            .math_randomseed => {
                // No persistent state in current VM — accept and ignore
                const values = try self.vm.allocator.alloc(Value, 0);
                return values;
            },

            // ====================
            // string library
            // ====================

            .string_len => {
                if (args.len == 0) return error.RuntimeError;
                const s = try self.toString(args[0]);
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .integer = @intCast(s.len) };
                return values;
            },
            .string_sub => {
                if (args.len < 2) return error.RuntimeError;
                const s = try self.toString(args[0]);
                const i_raw = try self.toInteger(args[1]);
                const j_raw: i64 = if (args.len >= 3) try self.toInteger(args[2]) else @as(i64, @intCast(s.len));
                const i: usize = if (i_raw < 0) @max(@as(usize, @intCast(@as(i64, @intCast(s.len)) + i_raw + 1)), 1) else @intCast(i_raw);
                const j: usize = if (j_raw < 0) @max(@as(usize, @intCast(@as(i64, @intCast(s.len)) + j_raw + 1)), @as(usize, 1)) else @min(@as(usize, @intCast(j_raw)), s.len);
                const values = try self.vm.allocator.alloc(Value, 1);
                if (i > j or i > s.len) {
                    values[0] = .{ .string = "" };
                } else {
                    const start: usize = @intCast(i - 1);
                    values[0] = .{ .string = s[start..@intCast(j)] };
                }
                return values;
            },
            .string_rep => {
                if (args.len < 2) return error.RuntimeError;
                const s = try self.toString(args[0]);
                const n = try self.toInteger(args[1]);
                const sep: []const u8 = if (args.len >= 3) try self.toString(args[2]) else "";
                if (n <= 0) {
                    const values = try self.vm.allocator.alloc(Value, 1);
                    values[0] = .{ .string = "" };
                    return values;
                }
                const total_len = @as(usize, @intCast(n)) * s.len + @max(@as(usize, @intCast(n)) - 1, 0) * sep.len;
                const buf = try self.vm.allocator.alloc(u8, total_len);
                var offset: usize = 0;
                for (0..@intCast(n)) |idx| {
                    if (idx > 0 and sep.len > 0) {
                        @memcpy(buf[offset..][0..sep.len], sep);
                        offset += sep.len;
                    }
                    if (s.len > 0) {
                        @memcpy(buf[offset..][0..s.len], s);
                        offset += s.len;
                    }
                }
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .string = buf };
                return values;
            },
            .string_reverse => {
                if (args.len == 0) return error.RuntimeError;
                const s = try self.toString(args[0]);
                const buf = try self.vm.allocator.alloc(u8, s.len);
                for (s, 0..) |c, i| buf[buf.len - 1 - i] = c;
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .string = buf };
                return values;
            },
            .string_upper => {
                if (args.len == 0) return error.RuntimeError;
                const s = try self.toString(args[0]);
                const buf = try self.vm.allocator.alloc(u8, s.len);
                for (s, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .string = buf };
                return values;
            },
            .string_lower => {
                if (args.len == 0) return error.RuntimeError;
                const s = try self.toString(args[0]);
                const buf = try self.vm.allocator.alloc(u8, s.len);
                for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .string = buf };
                return values;
            },
            .string_byte => {
                if (args.len == 0) return error.RuntimeError;
                const s = try self.toString(args[0]);
                const i_raw: i64 = if (args.len >= 2) try self.toInteger(args[1]) else 1;
                const j_raw: i64 = if (args.len >= 3) try self.toInteger(args[2]) else i_raw;
                const i: i64 = if (i_raw < 1) @max(@as(i64, @intCast(s.len)) + i_raw + 1, 1) else i_raw;
                const j: i64 = if (j_raw < 1) @max(@as(i64, @intCast(s.len)) + j_raw + 1, 1) else j_raw;
                if (i < 1 or @as(usize, @intCast(i)) > s.len or j < i) {
                    const values = try self.vm.allocator.alloc(Value, 0);
                    return values;
                }
                const count = @min(@as(usize, @intCast(j)), s.len) - @as(usize, @intCast(i)) + 1;
                const values = try self.vm.allocator.alloc(Value, count);
                var idx: usize = 0;
                var pos: usize = @intCast(i - 1);
                while (pos < s.len and idx < count) : ({ pos += 1; idx += 1; }) {
                    values[idx] = .{ .integer = s[pos] };
                }
                return values;
            },
            .string_char => {
                const buf = try self.vm.allocator.alloc(u8, args.len);
                for (args, 0..) |arg, i| {
                    const n = try self.toInteger(arg);
                    if (n < 0 or n > 255) return error.RuntimeError;
                    buf[i] = @intCast(n);
                }
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .string = buf };
                return values;
            },
            .string_format => {
                if (args.len == 0) return error.RuntimeError;
                const fmt = try self.toString(args[0]);
                var buf = try std.ArrayList(u8).initCapacity(self.vm.allocator, fmt.len * 2);
                defer buf.deinit(self.vm.allocator);
                var arg_idx: usize = 1;
                var fi: usize = 0;
                while (fi < fmt.len) {
                    if (fmt[fi] != '%') {
                        buf.append(self.vm.allocator, fmt[fi]) catch return error.OutOfMemory;
                        fi += 1;
                        continue;
                    }
                    fi += 1;
                    if (fi >= fmt.len) return error.RuntimeError;
                    if (fmt[fi] == '%') {
                        buf.append(self.vm.allocator, '%') catch return error.OutOfMemory;
                        fi += 1;
                        continue;
                    }
                    // skip flags/width/precision
                    if (fi < fmt.len and fmt[fi] == '-') fi += 1;
                    while (fi < fmt.len and fmt[fi] >= '0' and fmt[fi] <= '9') fi += 1;
                    if (fi < fmt.len and fmt[fi] == '.') {
                        fi += 1;
                        while (fi < fmt.len and fmt[fi] >= '0' and fmt[fi] <= '9') fi += 1;
                    }
                    if (fi >= fmt.len) return error.RuntimeError;
                    const spec = fmt[fi];
                    fi += 1;
                    if (arg_idx >= args.len) return error.RuntimeError;
                    const val = args[arg_idx];
                    arg_idx += 1;
                    switch (spec) {
                        'd', 'i' => {
                            const n = try self.toInteger(val);
                            var int_buf: [32]u8 = undefined;
                            const slice = std.fmt.bufPrint(&int_buf, "{}", .{n}) catch "0";
                            buf.appendSlice(self.vm.allocator, slice) catch return error.OutOfMemory;
                        },
                        'f' => {
                            const f = try self.toFloat(val);
                            self.formatFloatSimple(&buf, f, 6) catch return error.OutOfMemory;
                        },
                        's' => {
                            const s2 = switch (val) {
                                .string => |s3| s3,
                                else => blk: {
                                    const s3 = try self.toString(val);
                                    break :blk s3;
                                },
                            };
                            buf.appendSlice(self.vm.allocator, s2) catch return error.OutOfMemory;
                        },
                        'x' => {
                            const n = try self.toInteger(val);
                            var int_buf: [20]u8 = undefined;
                            const slice = std.fmt.bufPrint(&int_buf, "{x}", .{@as(u64, @bitCast(n))}) catch "0";
                            buf.appendSlice(self.vm.allocator, slice) catch return error.OutOfMemory;
                        },
                        'X' => {
                            const n = try self.toInteger(val);
                            var int_buf: [20]u8 = undefined;
                            const slice = std.fmt.bufPrint(&int_buf, "{X}", .{@as(u64, @bitCast(n))}) catch "0";
                            buf.appendSlice(self.vm.allocator, slice) catch return error.OutOfMemory;
                        },
                        'q' => {
                            const s2 = try self.toString(val);
                            try buf.append(self.vm.allocator, '"');
                            for (s2) |c| {
                                switch (c) {
                                    '"', '\\' => {
                                        try buf.append(self.vm.allocator, '\\');
                                        try buf.append(self.vm.allocator, c);
                                    },
                                    '\n' => try buf.appendSlice(self.vm.allocator, "\\n"),
                                    '\r' => try buf.appendSlice(self.vm.allocator, "\\r"),
                                    '\t' => try buf.appendSlice(self.vm.allocator, "\\t"),
                                    else => try buf.append(self.vm.allocator, c),
                                }
                            }
                            try buf.append(self.vm.allocator, '"');
                        },
                        else => {
                            // Unknown specifier — just write value as string
                            const s2 = try self.toString(val);
                            buf.appendSlice(self.vm.allocator, s2) catch return error.OutOfMemory;
                        },
                    }
                }
                const result = try buf.toOwnedSlice(self.vm.allocator);
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .string = result };
                return values;
            },
            .string_find => {
                if (args.len < 2) return error.RuntimeError;
                const s = try self.toString(args[0]);
                const pattern = try self.toString(args[1]);
                const init_raw: i64 = if (args.len >= 3) try self.toInteger(args[2]) else 1;
                const plain = args.len >= 4 and args[3].isTruthy();
                const init: usize = if (init_raw < 1) @max(@as(usize, @intCast(@as(i64, @intCast(s.len)) + init_raw + 1)), @as(usize, 1)) else @as(usize, @intCast(init_raw));
                if (init < 1 or init > s.len + 1) {
                    const values = try self.vm.allocator.alloc(Value, 1);
                    values[0] = .{ .nil = {} };
                    return values;
                }
                if (plain or !self.hasPatternMagic(pattern)) {
                    const start = if (init > 0) init - 1 else 0;
                    if (std.mem.indexOfPos(u8, s, start, pattern)) |pos| {
                        const values = try self.vm.allocator.alloc(Value, 2);
                        values[0] = .{ .integer = @intCast(pos + 1) };
                        values[1] = .{ .integer = @intCast(pos + pattern.len) };
                        return values;
                    }
                }
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .nil = {} };
                return values;
            },
            .string_match => {
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .nil = {} };
                return values;
            },
            .string_gmatch => {
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .nil = {} };
                return values;
            },
            .string_gsub => {
                if (args.len < 3) return error.RuntimeError;
                const s = try self.toString(args[0]);
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .string = s };
                return values;
            },
            .string_dump => {
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .nil = {} };
                return values;
            },

            // ====================
            // table library
            // ====================

            .table_insert => {
                if (args.len < 2 or args[0] != .table) return error.RuntimeError;
                const t = args[0].table;
                if (args.len == 2) {
                    // table.insert(t, value) — append
                    try t.appendArray(self.vm.allocator, args[1]);
                } else {
                    // table.insert(t, pos, value) — insert at position
                    const pos = try self.toInteger(args[1]);
                    if (pos < 1 or pos > t.array.items.len + 1) return error.RuntimeError;
                    const idx: usize = @intCast(pos - 1);
                    // Extend if needed
                    try t.array.append(self.vm.allocator, .{ .nil = {} });
                    // Shift elements right
                    var i = t.array.items.len - 1;
                    while (i > idx) : (i -= 1) {
                        t.array.items[i] = t.array.items[i - 1];
                    }
                    t.array.items[idx] = args[2];
                }
                const values = try self.vm.allocator.alloc(Value, 0);
                return values;
            },
            .table_remove => {
                if (args.len < 1 or args[0] != .table) return error.RuntimeError;
                const t = args[0].table;
                if (t.array.items.len == 0) return error.RuntimeError;
                const pos: usize = if (args.len >= 2) blk: {
                    const p = try self.toInteger(args[1]);
                    if (p < 1 or p > t.array.items.len) return error.RuntimeError;
                    break :blk @intCast(p - 1);
                } else t.array.items.len - 1;
                const removed = t.array.items[pos];
                // Shift elements left
                var i = pos;
                while (i < t.array.items.len - 1) : (i += 1) {
                    t.array.items[i] = t.array.items[i + 1];
                }
                t.array.items[t.array.items.len - 1] = .{ .nil = {} };
                // Shrink: remove trailing nils isn't needed, length handles it
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = removed;
                return values;
            },
            .table_sort => {
                if (args.len < 1 or args[0] != .table) return error.RuntimeError;
                const t = args[0].table;
                // Simple insertion sort (sufficient for correctness)
                const n = t.array.items.len;
                var i: usize = 1;
                while (i < n) : (i += 1) {
                    const key = t.array.items[i];
                    var j: usize = i;
                    while (j > 0) : (j -= 1) {
                        // Compare: items[j-1] > key
                        const should_swap = try self.lessThan(t.array.items[j - 1], key);
                        if (!should_swap) break;
                        t.array.items[j] = t.array.items[j - 1];
                    }
                    t.array.items[j] = key;
                }
                const values = try self.vm.allocator.alloc(Value, 0);
                return values;
            },
            .table_concat => {
                if (args.len < 1 or args[0] != .table) return error.RuntimeError;
                const t = args[0].table;
                const sep: []const u8 = if (args.len >= 2) try self.toString(args[1]) else "";
                const i_raw: i64 = if (args.len >= 3) try self.toInteger(args[2]) else 1;
                const j_raw: i64 = if (args.len >= 4) try self.toInteger(args[3]) else t.length();
                if (i_raw > j_raw) {
                    const values = try self.vm.allocator.alloc(Value, 1);
                    values[0] = .{ .string = "" };
                    return values;
                }
                // Calculate total size
                var total: usize = 0;
                var sep_count: usize = 0;
                var k: i64 = i_raw;
                while (k <= j_raw) : (k += 1) {
                    const idx: usize = @intCast(k - 1);
                    if (idx < t.array.items.len and !t.array.items[idx].isNil()) {
                        const s = try self.toString(t.array.items[idx]);
                        total += s.len;
                        sep_count += 1;
                    }
                }
                if (sep_count > 1) total += sep.len * (sep_count - 1);
                const buf = try self.vm.allocator.alloc(u8, total);
                var offset: usize = 0;
                var first = true;
                k = i_raw;
                while (k <= j_raw) : (k += 1) {
                    const idx: usize = @intCast(k - 1);
                    if (idx < t.array.items.len and !t.array.items[idx].isNil()) {
                        if (!first and sep.len > 0) {
                            @memcpy(buf[offset..][0..sep.len], sep);
                            offset += sep.len;
                        }
                        const s = try self.toString(t.array.items[idx]);
                        @memcpy(buf[offset..][0..s.len], s);
                        offset += s.len;
                        first = false;
                    }
                }
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .string = buf[0..offset] };
                return values;
            },
            .table_move => {
                if (args.len < 4 or args[0] != .table) return error.RuntimeError;
                const src = args[0].table;
                const dst = if (args.len >= 5 and args[4] == .table) args[4].table else src;
                const f = try self.toInteger(args[1]);
                const e = try self.toInteger(args[2]);
                const t_pos = try self.toInteger(args[3]);
                var i: i64 = f;
                var d: i64 = t_pos;
                while (i <= e) : ({
                    i += 1;
                    d += 1;
                }) {
                    try dst.setIndex(self.vm.allocator, d, src.getIndex(i));
                }
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = args[3]; // return dst table (via t_pos arg — actually should return dst)
                values[0] = .{ .table = dst };
                return values;
            },
            .table_pack => {
                const t = try Table.create(self.vm.allocator);
                for (args, 0..) |arg, i| {
                    try t.setIndex(self.vm.allocator, @intCast(i + 1), arg);
                }
                try t.setString("n", .{ .integer = @intCast(args.len) });
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .table = t };
                return values;
            },
            .table_unpack => {
                if (args.len < 1 or args[0] != .table) return error.RuntimeError;
                const t = args[0].table;
                const i_raw: i64 = if (args.len >= 2) try self.toInteger(args[1]) else 1;
                const j_raw: i64 = if (args.len >= 3) try self.toInteger(args[2]) else t.length();
                const count = @max(j_raw - i_raw + 1, 0);
                const values = try self.vm.allocator.alloc(Value, @intCast(count));
                var idx: usize = 0;
                var k: i64 = i_raw;
                while (k <= j_raw) : ({
                    k += 1;
                    idx += 1;
                }) {
                    values[idx] = t.getIndex(k);
                }
                return values;
            },
            .table_create => {
                const narr: usize = if (args.len >= 1) blk: {
                    const n = try self.toInteger(args[0]);
                    break :blk if (n > 0) @intCast(n) else @as(usize, 0);
                } else 0;
                const t = try Table.create(self.vm.allocator);
                // Pre-allocate array slots with nil
                for (0..narr) |_| {
                    try t.array.append(self.vm.allocator, .{ .nil = {} });
                }
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .table = t };
                return values;
            },

            // ====================
            // io library (native profile)
            // ====================

            .io_open => {
                if (args.len < 1) return error.RuntimeError;
                _ = try self.toString(args[0]);
                // File I/O stubbed in tree-walk VM — returns a table handle
                const handle = try Table.create(self.vm.allocator);
                try handle.setString("__type", .{ .string = "file" });
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .table = handle };
                return values;
            },
            .io_close => {
                // File closing not fully supported in tree-walk VM
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .nil = {} };
                return values;
            },
            .io_read => {
                // io.read() — stdin reading stubbed in tree-walk VM
                const fmt_str: []const u8 = if (args.len >= 1) try self.toString(args[0]) else "*l";
                _ = fmt_str;
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .string = "" };
                return values;
            },
            .io_write => {
                for (args) |arg| {
                    const s = try self.toString(arg);
                    try self.vm.stdout.writer.writeAll(s);
                }
                try self.vm.stdout.writer.flush();
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = args[0];
                return values;
            },
            .io_lines => {
                // Returns nil — file iteration not yet supported
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .nil = {} };
                return values;
            },
            .io_type => {
                if (args.len < 1) {
                    const values = try self.vm.allocator.alloc(Value, 1);
                    values[0] = .{ .nil = {} };
                    return values;
                }
                const values = try self.vm.allocator.alloc(Value, 1);
                if (args[0] == .table and !args[0].table.getString("__type").isNil()) {
                    values[0] = .{ .string = "file" };
                } else {
                    values[0] = .{ .nil = {} };
                }
                return values;
            },
            .io_flush => {
                try self.vm.stdout.writer.flush();
                const values = try self.vm.allocator.alloc(Value, 0);
                return values;
            },
            .io_tmpfile => {
                const handle = try Table.create(self.vm.allocator);
                try handle.setString("__type", .{ .string = "file" });
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .table = handle };
                return values;
            },
            .io_input => {
                // Return stdin handle
                const handle = try Table.create(self.vm.allocator);
                try handle.setString("__type", .{ .string = "file" });
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .table = handle };
                return values;
            },
            .io_output => {
                // Return stdout handle
                const handle = try Table.create(self.vm.allocator);
                try handle.setString("__type", .{ .string = "file" });
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .table = handle };
                return values;
            },
            .io_popen => {
                // popen not supported in tree-walk VM
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .nil = {} };
                return values;
            },
        }
    }


    // ====================
    // math library helpers
    // ====================

    const Number = union(enum) { integer: i64, float: f64, other: void };

    fn toString(self: *Parser, v: Value) anyerror![]const u8 {
        return switch (v) {
            .string => |s| s,
            .integer => |i| blk: {
                var buf: [32]u8 = undefined;
                const slice = std.fmt.bufPrint(&buf, "{}", .{i}) catch "0";
                break :blk try self.vm.allocator.dupe(u8, slice);
            },
            .float => |f| blk: {
                var buf: [64]u8 = undefined;
                const slice = std.fmt.bufPrint(&buf, "{d}", .{f}) catch "0";
                break :blk try self.vm.allocator.dupe(u8, slice);
            },
            .boolean => |b| if (b) "true" else "false",
            .nil => "nil",
            else => blk: {
                break :blk "";
            },
        };
    }

    fn lessThan(self: *Parser, a: Value, b: Value) anyerror!bool {
        _ = self;
        // Compare two values for table.sort (a > b means swap)
        if (a == .integer and b == .integer) return a.integer > b.integer;
        if (a == .float and b == .float) return a.float > b.float;
        if (a == .integer and b == .float) return @as(f64, @floatFromInt(a.integer)) > b.float;
        if (a == .float and b == .integer) return a.float > @as(f64, @floatFromInt(b.integer));
        if (a == .string and b == .string) {
            // Handle string slice lifetime issue by comparing byte by byte
            const sa = a.string;
            const sb = b.string;
            const min_len = @min(sa.len, sb.len);
            for (0..min_len) |i| {
                if (sa[i] != sb[i]) return sa[i] > sb[i];
            }
            return sa.len > sb.len;
        }
        return false;
    }

    fn hasPatternMagic(self: *Parser, pattern: []const u8) bool {
        _ = self;
        for (pattern) |c| {
            if (c == '^' or c == '$' or c == '(' or c == ')' or c == '%' or c == '.' or c == '[' or c == ']' or c == '*' or c == '+' or c == '-' or c == '?') return true;
        }
        return false;
    }

    fn formatFloatSimple(self: *Parser, buf: *std.ArrayList(u8), f: f64, prec: usize) !void {
        var result_buf: [128]u8 = undefined;
        const slice = switch (prec) {
            0 => std.fmt.bufPrint(&result_buf, "{d:.0}", .{f}) catch "0",
            1 => std.fmt.bufPrint(&result_buf, "{d:.1}", .{f}) catch "0",
            2 => std.fmt.bufPrint(&result_buf, "{d:.2}", .{f}) catch "0",
            3 => std.fmt.bufPrint(&result_buf, "{d:.3}", .{f}) catch "0",
            4 => std.fmt.bufPrint(&result_buf, "{d:.4}", .{f}) catch "0",
            5 => std.fmt.bufPrint(&result_buf, "{d:.5}", .{f}) catch "0",
            6 => std.fmt.bufPrint(&result_buf, "{d:.6}", .{f}) catch "0",
            7 => std.fmt.bufPrint(&result_buf, "{d:.7}", .{f}) catch "0",
            8 => std.fmt.bufPrint(&result_buf, "{d:.8}", .{f}) catch "0",
            9 => std.fmt.bufPrint(&result_buf, "{d:.9}", .{f}) catch "0",
            10 => std.fmt.bufPrint(&result_buf, "{d:.10}", .{f}) catch "0",
            12 => std.fmt.bufPrint(&result_buf, "{d:.12}", .{f}) catch "0",
            14 => std.fmt.bufPrint(&result_buf, "{d:.14}", .{f}) catch "0",
            else => std.fmt.bufPrint(&result_buf, "{d}", .{f}) catch "0",
        };
        try buf.appendSlice(self.vm.allocator, slice);
    }

    fn toNumber(self: *Parser, v: Value) anyerror!Number {
        _ = self;
        return switch (v) {
            .integer => |i| Number{ .integer = i },
            .float => |f| Number{ .float = f },
            .string => |s| blk: {
                // Try parsing string as number
                if (std.fmt.parseFloat(f64, s)) |f| break :blk Number{ .float = f } else |_| {}
                if (std.fmt.parseInt(i64, s, 10)) |i| break :blk Number{ .integer = i } else |_| {}
                return error.RuntimeError;
            },
            else => error.RuntimeError,
        };
    }

    fn toFloat(self: *Parser, v: Value) anyerror!f64 {
        const n = try self.toNumber(v);
        return switch (n) {
            .integer => |i| @as(f64, @floatFromInt(i)),
            .float => |f| f,
            .other => error.RuntimeError,
        };
    }

    fn toInteger(self: *Parser, v: Value) anyerror!i64 {
        const n = try self.toNumber(v);
        return switch (n) {
            .integer => |i| i,
            .float => |f| floatToInteger(f, .eq) orelse error.RuntimeError,
            .other => error.RuntimeError,
        };
    }

    fn compareNumbers(a: Number, b: Number, op: enum { lt, gt }) bool {
        return switch (op) {
            .lt => switch (a) {
                .integer => |ai| switch (b) {
                    .integer => |bi| ai < bi,
                    .float => |bf| @as(f64, @floatFromInt(ai)) < bf,
                    .other => false,
                },
                .float => |af| switch (b) {
                    .integer => |bi| af < @as(f64, @floatFromInt(bi)),
                    .float => |bf| af < bf,
                    .other => false,
                },
                .other => false,
            },
            .gt => switch (a) {
                .integer => |ai| switch (b) {
                    .integer => |bi| ai > bi,
                    .float => |bf| @as(f64, @floatFromInt(ai)) > bf,
                    .other => false,
                },
                .float => |af| switch (b) {
                    .integer => |bi| af > @as(f64, @floatFromInt(bi)),
                    .float => |bf| af > bf,
                    .other => false,
                },
                .other => false,
            },
        };
    }

    fn numberToValue(n: Number) Value {
        return switch (n) {
            .integer => |i| .{ .integer = i },
            .float => |f| .{ .float = f },
            .other => .{ .nil = {} },
        };
    }

    fn mathTrig(self: *Parser, args: []const Value, comptime func: anytype) anyerror![]const Value {
        if (args.len == 0) return error.RuntimeError;
        const f = try self.toFloat(args[0]);
        const values = try self.vm.allocator.alloc(Value, 1);
        values[0] = .{ .float = func(f) };
        return values;
    }

    fn errorLevelLine(self: *Parser, level: i64) ?usize {
        if (level <= 0) return null;
        if (level == 1) return self.active_call_line orelse self.peek().line;
        const frame_level: usize = @intCast(level - 1);
        if (self.vm.frames.items.len < frame_level) return null;
        const frame_index = self.vm.frames.items.len - frame_level;
        return self.vm.frames.items[frame_index].call_line;
    }

    fn protectedCall(self: *Parser, callee: Value, args: []const Value, handler: ?Value) anyerror![]const Value {
        const saved_message = self.vm.runtime_error_message;
        const saved_value = self.vm.runtime_error_value;
        const saved_line = self.vm.runtime_error_line;
        const saved_metamethod = self.vm.runtime_error_metamethod;
        self.vm.clearRuntimeError();
        const returns = self.invokeProtectedTarget(callee, args) catch |err| switch (err) {
            error.Yield => {
                try self.appendThreadContinuation(.{
                    .kind = .pending_protected_call,
                    .local_name = null,
                    .local_names = &.{},
                    .assign_targets = &.{},
                    .prefix_values = &.{},
                    .pos = self.pos,
                    .body_end = self.limit,
                });
                return err;
            },
            error.RuntimeError => {
                const error_value = self.vm.currentRuntimeErrorValue();
                self.vm.runtime_error_message = saved_message;
                self.vm.runtime_error_value = saved_value;
                self.vm.runtime_error_line = saved_line;
                self.vm.runtime_error_metamethod = saved_metamethod;
                const handled = if (handler) |h| try self.applyErrorHandler(h, error_value) else error_value;
                const values = try self.vm.allocator.alloc(Value, 2);
                values[0] = .{ .boolean = false };
                values[1] = handled;
                self.vm.runtime_error_message = saved_message;
                self.vm.runtime_error_value = saved_value;
                self.vm.runtime_error_line = saved_line;
                self.vm.runtime_error_metamethod = saved_metamethod;
                return values;
            },
            else => return err,
        };
        self.vm.runtime_error_message = saved_message;
        self.vm.runtime_error_value = saved_value;
        self.vm.runtime_error_line = saved_line;
        self.vm.runtime_error_metamethod = saved_metamethod;
        const values = try self.vm.allocator.alloc(Value, returns.len + 1);
        values[0] = .{ .boolean = true };
        @memcpy(values[1..], returns);
        return values;
    }

    fn applyErrorHandler(self: *Parser, handler: Value, initial_error: Value) anyerror!Value {
        var current_error = initial_error;
        var attempts: usize = 0;
        while (true) {
            self.vm.clearRuntimeError();
            const returns = self.invokeCallable(handler, &.{current_error}) catch |handler_err| switch (handler_err) {
                error.RuntimeError => {
                    current_error = self.vm.currentRuntimeErrorValue();
                    attempts += 1;
                    if (attempts >= 64) return current_error;
                    continue;
                },
                else => return handler_err,
            };
            return if (returns.len > 0) returns[0] else Value{ .nil = {} };
        }
    }

    fn invokeProtectedTarget(self: *Parser, callee: Value, args: []const Value) anyerror![]const Value {
        if (callee == .table) {
            const metamethod = callee.table.rawMetafield("__call");
            if (metamethod == .function or metamethod == .builtin) {
                var call_args: std.ArrayList(Value) = .empty;
                try call_args.append(self.vm.allocator, callee);
                try call_args.appendSlice(self.vm.allocator, args);
                return self.invokeCallable(metamethod, call_args.items);
            }
        }
        return self.invokeCallable(callee, args);
    }

    fn callWrappedThread(self: *Parser, thread: *Thread, args: []const Value) anyerror![]const Value {
        const resumed = try self.resumeThread(thread, args);
        if (resumed.len > 0 and resumed[0] == .boolean and resumed[0].boolean) return resumed[1..];
        const error_value = if (resumed.len > 1) resumed[1] else Value{ .string = "cannot resume dead coroutine" };
        const message = try valueToStringForTostring(self.vm.allocator, error_value);
        self.vm.setRuntimeErrorValueAt(self.active_call_line orelse self.peek().line, error_value, message);
        return error.RuntimeError;
    }

    fn closeThread(self: *Parser, thread: *Thread) anyerror![]const Value {
        switch (thread.status) {
            .dead => {
                if (thread.close_error) |error_value| {
                    thread.close_error = null;
                    const values = try self.vm.allocator.alloc(Value, 2);
                    values[0] = .{ .boolean = false };
                    values[1] = error_value;
                    return values;
                }
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .boolean = true };
                return values;
            },
            .suspended => {
                thread.status = .dead;
                self.cleanupThreadFrame(thread);
                const values = try self.vm.allocator.alloc(Value, 1);
                values[0] = .{ .boolean = true };
                return values;
            },
            .normal => {
                self.vm.setRuntimeErrorAt(self.active_call_line orelse self.peek().line, "cannot close a normal coroutine");
                return error.RuntimeError;
            },
            .running => {
                if (self.vm.current_thread == null) {
                    self.vm.setRuntimeErrorAt(self.active_call_line orelse self.peek().line, "cannot close main thread");
                    return error.RuntimeError;
                }
                if (self.vm.current_thread.? == thread) {
                    thread.close_error = null;
                    thread.status = .dead;
                    self.cleanupThreadFrame(thread);
                    return error.CoroutineClosed;
                }
                self.vm.setRuntimeErrorAt(self.active_call_line orelse self.peek().line, "cannot close a running coroutine");
                return error.RuntimeError;
            },
        }
    }

    fn resumeThread(self: *Parser, thread: *Thread, args: []const Value) anyerror![]const Value {
        if (thread.status == .dead) {
            const values = try self.vm.allocator.alloc(Value, 2);
            values[0] = .{ .boolean = false };
            values[1] = .{ .string = "cannot resume dead coroutine" };
            return values;
        }
        if (thread.status == .running or thread.status == .normal) {
            const values = try self.vm.allocator.alloc(Value, 2);
            values[0] = .{ .boolean = false };
            values[1] = .{ .string = "cannot resume non-suspended coroutine" };
            return values;
        }
        const caller_thread = self.vm.current_thread;
        if (caller_thread) |caller| caller.status = .normal;
        thread.status = .running;
        thread.vm.current_thread = thread;
        const returns = self.resumeThreadBody(thread, args) catch |err| switch (err) {
            error.Yield => {
                thread.status = .suspended;
                thread.vm.current_thread = null;
                if (caller_thread) |caller| caller.status = .running;
                return self.coroutineResult(true, thread.yield_values);
            },
            error.RuntimeError => {
                const error_value = thread.vm.currentRuntimeErrorValue();
                thread.status = .dead;
                thread.close_error = error_value;
                thread.vm.current_thread = null;
                self.cleanupThreadFrame(thread);
                if (caller_thread) |caller| caller.status = .running;
                return self.coroutineResult(false, &.{error_value});
            },
            error.CoroutineClosed => {
                thread.status = .dead;
                thread.close_error = null;
                thread.vm.current_thread = null;
                self.cleanupThreadFrame(thread);
                if (caller_thread) |caller| caller.status = .running;
                return self.coroutineResult(true, &.{});
            },
            else => return err,
        };
        thread.status = .dead;
        thread.vm.current_thread = null;
        self.cleanupThreadFrame(thread);
        if (caller_thread) |caller| caller.status = .running;
        return self.coroutineResult(true, returns);
    }

    fn resumeThreadBody(self: *Parser, thread: *Thread, args: []const Value) anyerror![]const Value {
        if (thread.continuations.items.len > 0) {
            var payload = args;
            while (thread.continuations.items.len > 0) {
                const cont = thread.continuations.orderedRemove(0);
                payload = try self.resumeContinuation(thread, cont, payload);
            }
            return payload;
        }
        var entry = Parser{ .vm = &thread.vm, .pos = 0, .limit = thread.vm.tokens.len, .evaluate = true };
        return entry.executeFunction(thread.function, args);
    }

    fn resumeContinuation(self: *Parser, thread: *Thread, cont: CoroutineContinuation, payload: []const Value) anyerror![]const Value {
        switch (cont.kind) {
            .resume_body => {
                if (cont.local_name) |name| {
                    try thread.vm.declare(name, if (payload.len > 0) payload[0] else Value{ .nil = {} });
                }
                var body = Parser{ .vm = &thread.vm, .pos = cont.pos, .limit = cont.body_end, .evaluate = true };
                const signal = try body.parseBlock();
                return self.finishSuspendedFunction(thread, signal);
            },
            .pending_local_assignment => {
                var continuation_parser = Parser{ .vm = &thread.vm, .pos = cont.pos, .limit = cont.body_end, .evaluate = true };
                const values = try continuation_parser.finishResumedExpressionList(cont.prefix_values, payload);
                for (cont.local_names, 0..) |name, i| {
                    try thread.vm.declare(name, if (i < values.len) values[i] else Value{ .nil = {} });
                }
                var body = Parser{ .vm = &thread.vm, .pos = continuation_parser.pos, .limit = cont.body_end, .evaluate = true };
                const signal = try body.parseBlock();
                return self.finishSuspendedFunction(thread, signal);
            },
            .pending_assignment => {
                var continuation_parser = Parser{ .vm = &thread.vm, .pos = cont.pos, .limit = cont.body_end, .evaluate = true };
                const values = try continuation_parser.finishResumedExpressionList(cont.prefix_values, payload);
                for (cont.assign_targets, 0..) |target, i| {
                    const value = if (i < values.len) values[i] else Value{ .nil = {} };
                    switch (target.kind) {
                        .name => try thread.vm.assignName(target.name, value),
                        .string_field => try continuation_parser.setTableValue(target.table.?, .{ .string = target.key_string }, value, cont.pos),
                        .index => try continuation_parser.setTableValue(target.table.?, target.key_value, value, cont.pos),
                    }
                }
                const signal = try continuation_parser.parseBlock();
                return self.finishSuspendedFunction(thread, signal);
            },
            .pending_return => {
                var continuation_parser = Parser{ .vm = &thread.vm, .pos = cont.pos, .limit = cont.body_end, .evaluate = true };
                const values = try continuation_parser.finishResumedExpressionList(cont.prefix_values, payload);
                self.popSuspendedFunction(thread);
                return values;
            },
            .pending_protected_call => {
                return self.coroutineResult(true, payload);
            },
            .pending_expression => {
                var continuation_parser = Parser{ .vm = &thread.vm, .pos = cont.pos, .limit = cont.body_end, .evaluate = true };
                const left = if (payload.len > 0) payload[0] else Value{ .nil = {} };
                const value = try continuation_parser.continueExpression(left, cont.expression_min_prec);
                self.advanceNextContinuationPos(thread, cont.pos, continuation_parser.pos);
                return self.singleValuePayload(thread, value);
            },
            .pending_binary => {
                var continuation_parser = Parser{ .vm = &thread.vm, .pos = cont.pos, .limit = cont.body_end, .evaluate = true };
                const right = if (payload.len > 0) payload[0] else Value{ .nil = {} };
                const combined = try continuation_parser.applyResumedBinaryValue(cont.binary_op, cont.binary_left, right);
                const value = try continuation_parser.continueExpression(combined, cont.expression_min_prec);
                self.advanceNextContinuationPos(thread, cont.pos, continuation_parser.pos);
                return self.singleValuePayload(thread, value);
            },
            .pending_call => {
                var continuation_parser = Parser{ .vm = &thread.vm, .pos = cont.pos, .limit = cont.body_end, .evaluate = true };
                const args = try continuation_parser.finishResumedExpressionList(cont.prefix_values, payload);
                try continuation_parser.consumeCloseParen(cont.call_open_line);
                self.advanceNextContinuationPos(thread, cont.pos, continuation_parser.pos);
                return continuation_parser.invokePreparedCall(cont.call_callee, args, cont.call_open_line, cont.call_prepend_callee);
            },
        }
    }

    fn combineContinuationValues(self: *Parser, leading: []const Value, payload: []const Value) ![]const Value {
        if (leading.len == 0) return payload;
        const values = try self.vm.allocator.alloc(Value, leading.len + payload.len);
        @memcpy(values[0..leading.len], leading);
        @memcpy(values[leading.len..], payload);
        return values;
    }

    fn finishResumedExpressionList(self: *Parser, leading: []const Value, payload: []const Value) ![]const Value {
        var values: std.ArrayList(Value) = .empty;
        try values.appendSlice(self.vm.allocator, leading);
        if (self.match(.comma)) {
            try values.append(self.vm.allocator, if (payload.len > 0) payload[0] else Value{ .nil = {} });
            try self.parseExpressionList(&values);
        } else {
            try values.appendSlice(self.vm.allocator, payload);
        }
        return values.toOwnedSlice(self.vm.allocator);
    }

    fn singleValuePayload(_: *Parser, thread: *Thread, value: Value) ![]const Value {
        const values = try thread.vm.allocator.alloc(Value, 1);
        values[0] = value;
        return values;
    }

    fn advanceNextContinuationPos(_: *Parser, thread: *Thread, old_pos: usize, new_pos: usize) void {
        if (new_pos == old_pos or thread.continuations.items.len == 0) return;
        const next = &thread.continuations.items[0];
        if (next.pos != old_pos) return;
        switch (next.kind) {
            .pending_local_assignment,
            .pending_assignment,
            .pending_return,
            .pending_call,
            .pending_expression,
            .pending_binary,
            => next.pos = new_pos,
            .resume_body => {
                if (next.local_name == null) next.pos = new_pos;
            },
            .pending_protected_call => {},
        }
    }

    fn finishSuspendedFunction(_: *Parser, thread: *Thread, signal: ExecSignal) anyerror![]const Value {
        const returns = switch (signal) {
            .normal => &.{},
            .break_loop => return error.UnsupportedFeature,
            .returned => |values| values,
        };
        if (thread.vm.frames.items.len > 0) _ = thread.vm.frames.pop();
        if (thread.vm.scopes.items.len > 1) thread.vm.popScope();
        return returns;
    }

    fn popSuspendedFunction(_: *Parser, thread: *Thread) void {
        if (thread.vm.frames.items.len > 0) _ = thread.vm.frames.pop();
        if (thread.vm.scopes.items.len > 1) thread.vm.popScope();
    }

    fn cleanupThreadFrame(_: *Parser, thread: *Thread) void {
        if (thread.vm.frames.items.len > 0) _ = thread.vm.frames.pop();
        if (thread.vm.scopes.items.len > 1) thread.vm.popScope();
    }

    fn coroutineResult(self: *Parser, ok: bool, payload: []const Value) ![]const Value {
        const values = try self.vm.allocator.alloc(Value, payload.len + 1);
        values[0] = .{ .boolean = ok };
        @memcpy(values[1..], payload);
        return values;
    }

    fn ipairsIter(self: *Parser, args: []const Value) ![]const Value {
        if (args.len < 2 or args[0] != .table) return error.RuntimeError;
        const index = try valueToInteger(args[1]) + 1;
        const value = args[0].table.getIndex(index);
        if (value.isNil()) {
            const values = try self.vm.allocator.alloc(Value, 1);
            values[0] = .{ .nil = {} };
            return values;
        }
        const values = try self.vm.allocator.alloc(Value, 2);
        values[0] = .{ .integer = index };
        values[1] = value;
        return values;
    }

    fn nextTable(self: *Parser, args: []const Value) ![]const Value {
        if (args.len == 0 or args[0] != .table) return error.RuntimeError;
        const table = args[0].table;
        const key = if (args.len > 1) args[1] else Value{ .nil = {} };
        var entries: std.ArrayList(struct { key: Value, value: Value }) = .empty;
        var idx: usize = 0;
        while (idx < table.array.items.len) : (idx += 1) {
            const value = table.array.items[idx];
            if (!value.isNil()) try entries.append(self.vm.allocator, .{ .key = .{ .integer = @intCast(idx + 1) }, .value = value });
        }
        var int_iter = table.integers.iterator();
        while (int_iter.next()) |entry| {
            if (!entry.value_ptr.*.isNil()) try entries.append(self.vm.allocator, .{ .key = .{ .integer = entry.key_ptr.* }, .value = entry.value_ptr.* });
        }
        var float_iter = table.floats.iterator();
        while (float_iter.next()) |entry| {
            if (!entry.value_ptr.*.isNil()) {
                const float_key: f64 = @bitCast(entry.key_ptr.*);
                try entries.append(self.vm.allocator, .{ .key = .{ .float = float_key }, .value = entry.value_ptr.* });
            }
        }
        var string_iter = table.strings.iterator();
        while (string_iter.next()) |entry| {
            if (!entry.value_ptr.*.isNil()) try entries.append(self.vm.allocator, .{ .key = .{ .string = entry.key_ptr.* }, .value = entry.value_ptr.* });
        }
        var table_iter = table.table_keys.iterator();
        while (table_iter.next()) |entry| {
            if (!entry.value_ptr.*.isNil()) try entries.append(self.vm.allocator, .{ .key = .{ .table = entry.key_ptr.* }, .value = entry.value_ptr.* });
        }
        var function_iter = table.function_keys.iterator();
        while (function_iter.next()) |entry| {
            if (!entry.value_ptr.*.isNil()) try entries.append(self.vm.allocator, .{ .key = .{ .function = entry.key_ptr.* }, .value = entry.value_ptr.* });
        }
        var builtin_iter = table.builtin_keys.iterator();
        while (builtin_iter.next()) |entry| {
            if (!entry.value_ptr.*.isNil()) try entries.append(self.vm.allocator, .{ .key = .{ .builtin = entry.key_ptr.* }, .value = entry.value_ptr.* });
        }
        if (!table.bool_false.isNil()) try entries.append(self.vm.allocator, .{ .key = .{ .boolean = false }, .value = table.bool_false });
        if (!table.bool_true.isNil()) try entries.append(self.vm.allocator, .{ .key = .{ .boolean = true }, .value = table.bool_true });

        var return_index: usize = 0;
        if (!key.isNil()) {
            var found = false;
            for (entries.items, 0..) |entry, i| {
                if (valuesEqual(entry.key, key)) {
                    return_index = i + 1;
                    found = true;
                    break;
                }
            }
            if (!found) {
                self.vm.setRuntimeErrorAt(self.peek().line, "invalid key to 'next'");
                return error.RuntimeError;
            }
        }
        if (return_index < entries.items.len) {
            const values = try self.vm.allocator.alloc(Value, 2);
            values[0] = entries.items[return_index].key;
            values[1] = entries.items[return_index].value;
            return values;
        }
        const values = try self.vm.allocator.alloc(Value, 1);
        values[0] = .{ .nil = {} };
        return values;
    }

    fn executeFunction(self: *Parser, function: *Function, args: []const Value) anyerror![]const Value {
        const extra = if (args.len > function.params.len) args[function.params.len..] else &.{};
        try self.vm.pushScope(if (function.vararg) extra else &.{}, function.vararg);
        try self.vm.frames.append(self.vm.allocator, .{
            .scope_start = self.vm.scopes.items.len - 1,
            .lexical_scope_len = function.lexical_scope_len,
            .env = function.env,
            .captures = &function.captures,
            .body_end = function.body_end,
            .call_line = self.active_call_line,
        });
        for (function.params, 0..) |param, i| {
            try self.vm.declare(param, if (i < args.len) args[i] else Value{ .nil = {} });
        }
        var body = Parser{ .vm = self.vm, .pos = function.body_start, .limit = function.body_end, .evaluate = self.evaluate };
        const signal = body.parseBlock() catch |err| switch (err) {
            error.Yield => return error.Yield,
            else => {
                _ = self.vm.frames.pop();
                self.vm.popScope();
                return err;
            },
        };
        const returns = switch (signal) {
            .normal => &.{},
            .break_loop => return error.UnsupportedFeature,
            .returned => |values| values,
        };
        _ = self.vm.frames.pop();
        self.vm.popScope();
        return returns;
    }

    fn primary(self: *Parser) anyerror!Value {
        const token = self.advance();
        self.last_primary_name = null;
        self.last_primary_scope = .unknown;
        switch (token.tag) {
            .number => return parseNumber(token.lexeme),
            .string => return .{ .string = token.lexeme },
            .ellipsis => {
                const values = self.vm.currentVarargs();
                self.last_call_values = values;
                return if (values.len == 0) Value{ .nil = {} } else values[0];
            },
            .ident => {
                const resolved = self.vm.lookupDetailed(token.lexeme);
                self.last_primary_name = token.lexeme;
                self.last_primary_scope = resolved.scope;
                return resolved.value;
            },
            .keyword => {
                if (std.mem.eql(u8, token.lexeme, "nil")) return .{ .nil = {} };
                if (std.mem.eql(u8, token.lexeme, "true")) return .{ .boolean = true };
                if (std.mem.eql(u8, token.lexeme, "false")) return .{ .boolean = false };
                if (std.mem.eql(u8, token.lexeme, "function")) return self.parseAnonymousFunction(token.line);
                return error.UnsupportedFeature;
            },
            .lparen => {
                const value = try self.expression(0);
                try self.consumeCloseParen(token.line);
                self.last_call_values = null;
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
            if (self.match(.lbracket)) {
                const bracket_line = self.tokens()[self.pos - 1].line;
                const key = try self.expression(0);
                try self.consumeCloseBracket(bracket_line);
                try self.consume(.assign);
                try self.rawSetTableValue(table, key, try self.expression(0), bracket_line);
            } else if (self.peek().tag == .ident and self.peekOffset(1).tag == .assign) {
                const key = try self.consumeIdent();
                try self.consume(.assign);
                try table.setString(key, try self.expression(0));
            } else {
                self.last_call_values = null;
                const first_value = try self.expression(0);
                if (self.peek().tag == .comma or self.peek().tag == .semi) {
                    try table.appendArray(self.vm.allocator, first_value);
                } else if (self.last_call_values) |values| {
                    for (values) |value| try table.appendArray(self.vm.allocator, value);
                } else {
                    try table.appendArray(self.vm.allocator, first_value);
                }
            }
            if (self.match(.comma) or self.match(.semi)) {
                if (self.match(.rbrace)) break;
                continue;
            }
            try self.consume(.rbrace);
            break;
        }
        self.last_call_values = null;
        return .{ .table = table };
    }

    fn findEnd(self: *Parser, start: usize) !usize {
        return self.findEndFor(start, null, 1);
    }

    fn findEndFor(self: *Parser, start: usize, opener: ?[]const u8, opener_line: usize) !usize {
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
        if (opener) |word| {
            self.vm.setSyntaxErrorAt(
                self.peekOffset(self.limit - self.pos).line,
                try std.fmt.allocPrint(self.vm.allocator, "'end' expected (to close '{s}' at line {d}) near <eof>", .{ word, opener_line }),
            );
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
    fn consumeCloseParen(self: *Parser, open_line: usize) !void {
        if (self.match(.rparen)) return;
        const near = try tokenNearText(self.vm.allocator, self.peek());
        self.vm.setSyntaxErrorAt(
            self.peek().line,
            try std.fmt.allocPrint(self.vm.allocator, "')' expected (to close '(' at line {d}) near {s}", .{ open_line, near }),
        );
        return error.SyntaxError;
    }
    fn consumeCloseBracket(self: *Parser, open_line: usize) !void {
        if (self.match(.rbracket)) return;
        const near = try tokenNearText(self.vm.allocator, self.peek());
        self.vm.setSyntaxErrorAt(
            self.peek().line,
            try std.fmt.allocPrint(self.vm.allocator, "']' expected (to close '[' at line {d}) near {s}", .{ open_line, near }),
        );
        return error.SyntaxError;
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
    return runLevel0WithRunContext(allocator, source, args, "stdin", 0);
}

pub fn runLevel0WithRunContext(
    allocator: std.mem.Allocator,
    source: []const u8,
    args: []const []const u8,
    error_chunk_name: []const u8,
    error_line_offset: usize,
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
    var vm = try Vm.initWithContext(allocator, token_slice, try varargs.toOwnedSlice(allocator), error_chunk_name, error_line_offset);
    var parser = Parser{ .vm = &vm, .pos = 0, .limit = token_slice.len, .evaluate = true };
    _ = parser.parseBlock() catch |err| switch (err) {
        error.RuntimeError => return runtimeErrorAt(
            allocator,
            vm.runtime_error_line,
            vm.runtime_error_message orelse "runtime error",
            vm.runtime_error_metamethod,
        ),
        error.SyntaxError => return syntaxErrorAt(allocator, vm.syntax_error_line, vm.syntax_error_message orelse "syntax error"),
        error.UnsupportedFeature => return unsupported(allocator, "outside-level0-subset"),
        else => return err,
    };
    if (parser.peekKeyword("end") or parser.peekKeyword("until") or parser.peekKeyword("else")) {
        const token = parser.peek();
        return syntaxErrorAt(allocator, token.line, try std.fmt.allocPrint(allocator, "<eof> expected near '{s}'", .{token.lexeme}));
    }
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
    ends_block: bool,
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
    var function_barriers: std.ArrayList(usize) = .empty;
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
            const visible_path = visibleBlockPath(block_stack.items, function_barriers.items);
            for (labels.items) |existing| {
                if (existing.block_id == block_id and std.mem.eql(u8, existing.name, label.lexeme)) {
                    return .{ .line = label.line, .message = try std.fmt.allocPrint(allocator, "label '{s}' already defined on line {d}", .{ label.lexeme, label.line }) };
                }
                if (std.mem.eql(u8, existing.name, label.lexeme) and blockDepthInPath(visible_path, existing.block_id) != null) {
                    return .{ .line = label.line, .message = try std.fmt.allocPrint(allocator, "label '{s}' already defined on line {d}", .{ label.lexeme, existing.line }) };
                }
            }
            try labels.append(allocator, .{ .name = label.lexeme, .line = label.line, .index = i, .block_id = block_id, .ends_block = labelTerminatesBlock(tokens, i) });
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
                .block_path = try allocator.dupe(usize, visibleBlockPath(block_stack.items, function_barriers.items)),
            });
            i += 1;
            continue;
        }

        if (token.tag == .keyword and std.mem.eql(u8, token.lexeme, "local")) {
            try collectLocalNames(allocator, tokens, i, block_stack.items[block_stack.items.len - 1], &locals);
        }

        if (token.tag == .keyword or (token.tag == .ident and std.mem.eql(u8, token.lexeme, "elseif"))) {
            if (std.mem.eql(u8, token.lexeme, "end") or std.mem.eql(u8, token.lexeme, "until")) {
                popBlock(&block_stack, &function_barriers);
            } else if (std.mem.eql(u8, token.lexeme, "elseif")) {
                popBlock(&block_stack, &function_barriers);
            } else if (std.mem.eql(u8, token.lexeme, "else")) {
                popBlock(&block_stack, &function_barriers);
                try block_stack.append(allocator, next_block_id);
                next_block_id += 1;
            } else if (std.mem.eql(u8, token.lexeme, "then") or
                std.mem.eql(u8, token.lexeme, "do") or
                std.mem.eql(u8, token.lexeme, "repeat"))
            {
                try block_stack.append(allocator, next_block_id);
                next_block_id += 1;
            } else if (std.mem.eql(u8, token.lexeme, "function")) {
                try block_stack.append(allocator, next_block_id);
                try function_barriers.append(allocator, next_block_id);
                next_block_id += 1;
            }
        }
    }

    for (gotos.items) |goto_ref| {
        const label = findVisibleLabel(labels.items, goto_ref) orelse {
            return .{ .line = goto_ref.line, .message = try std.fmt.allocPrint(allocator, "no visible label '{s}' for <goto> at line {d}", .{ goto_ref.name, goto_ref.line }) };
        };
        if (label.block_id == goto_ref.block_id and goto_ref.index < label.index and !label.ends_block) {
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

fn popBlock(block_stack: *std.ArrayList(usize), function_barriers: *std.ArrayList(usize)) void {
    if (block_stack.items.len <= 1) return;
    const popped = block_stack.pop().?;
    if (function_barriers.items.len > 0 and function_barriers.items[function_barriers.items.len - 1] == popped) {
        _ = function_barriers.pop();
    }
}

fn visibleBlockPath(block_stack: []const usize, function_barriers: []const usize) []const usize {
    if (function_barriers.len == 0) return block_stack;
    const function_block_id = function_barriers[function_barriers.len - 1];
    for (block_stack, 0..) |block_id, depth| {
        if (block_id == function_block_id) return block_stack[depth..];
    }
    return block_stack;
}

fn labelTerminatesBlock(tokens: []const Token, label_index: usize) bool {
    var p = label_index + 3;
    while (p < tokens.len) {
        const token = tokens[p];
        if (token.tag == .semi) {
            p += 1;
            continue;
        }
        if (token.tag == .coloncolon and p + 2 < tokens.len and tokens[p + 1].tag == .ident and tokens[p + 2].tag == .coloncolon) {
            p += 3;
            continue;
        }
        if (token.tag == .eof) return true;
        if (token.tag == .keyword and (std.mem.eql(u8, token.lexeme, "end") or
            std.mem.eql(u8, token.lexeme, "until") or
            std.mem.eql(u8, token.lexeme, "else")))
        {
            return true;
        }
        if ((token.tag == .keyword or token.tag == .ident) and std.mem.eql(u8, token.lexeme, "elseif")) {
            return true;
        }
        return false;
    }
    return true;
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
    if (classifyAdvancedHookBoundary(tokens)) |boundary| return advanced_hooks.reasonName(boundary);
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const token = tokens[i];
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

        if (std.mem.eql(u8, token.lexeme, "collectgarbage")) return .gc_weak_finalization;
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
        if (std.mem.eql(u8, token.lexeme, "setmetatable")) self.saw_metatable = true;
        return null;
    }

    fn finish(self: AdvancedScanState) ?advanced_hooks.HookBoundary {
        if (self.saw_metatable and self.saw_protected) return .cross_boundary_advanced;
        if (self.saw_binary_dump) return .binary_dynamic_gates;
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

fn runtimeErrorAt(allocator: std.mem.Allocator, line: usize, message: []const u8, metamethod: ?[]const u8) !VmResult {
    return .{
        .state = .runtime_error,
        .stdout = "",
        .stderr = try std.fmt.allocPrint(
            allocator,
            "ziglua-vm: runtime-error:{d}:{s}:{s}\n",
            .{ line, metamethod orelse "-", message },
        ),
        .exit_code = 1,
        .unsupported_reason = null,
    };
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
            ':' => .colon,
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
        .float => |f| floatToInteger(f, .eq) orelse error.RuntimeError,
        else => error.RuntimeError,
    };
}

const floatTableKey = vm_table.floatTableKey;

fn tableIndexErrorMessage(key: Value) []const u8 {
    return switch (key) {
        .float => |f| if (f != f) "table index is NaN" else "table index is nil",
        else => "table index is nil",
    };
}

fn unaryMinus(vm: *Vm, line: usize, value: Value) !Value {
    return switch (value) {
        .integer => |i| .{ .integer = -i },
        .float => |f| .{ .float = -f },
        else => {
            vm.setRuntimeErrorAt(line, try std.fmt.allocPrint(vm.allocator, "attempt to perform arithmetic on a {s} value", .{valueTypeName(value)}));
            return error.RuntimeError;
        },
    };
}

fn lengthValueRaw(vm: *Vm, line: usize, value: Value) !Value {
    return switch (value) {
        .string => |s| .{ .integer = @intCast(s.len) },
        .table => |t| .{ .integer = t.length() },
        else => {
            vm.setRuntimeErrorAt(line, try std.fmt.allocPrint(vm.allocator, "attempt to get length of a {s} value", .{valueTypeName(value)}));
            return error.RuntimeError;
        },
    };
}

fn bitNot(value: Value) !Value {
    return .{ .integer = ~(try valueToInteger(value)) };
}

fn binaryMetamethodName(tag: TokenTag) ?[]const u8 {
    return switch (tag) {
        .plus => "__add",
        .minus => "__sub",
        .star => "__mul",
        .slash => "__div",
        .floor_div => "__idiv",
        .percent => "__mod",
        .concat => "__concat",
        .amp => "__band",
        .pipe => "__bor",
        .tilde => "__bxor",
        .shl => "__shl",
        .shr => "__shr",
        else => null,
    };
}

fn binaryOperandsAreRawSupported(tag: TokenTag, left: Value, right: Value) bool {
    return switch (tag) {
        .plus, .minus, .star, .slash, .floor_div, .percent => (left == .integer or left == .float) and (right == .integer or right == .float),
        .concat => canConcatRaw(left) and canConcatRaw(right),
        .amp, .pipe, .tilde, .shl, .shr => canValueToInteger(left) and canValueToInteger(right),
        .lt, .le, .gt, .ge => ((left == .integer or left == .float) and (right == .integer or right == .float)) or (left == .string and right == .string),
        .eq, .ne => true,
        else => true,
    };
}

fn canConcatRaw(value: Value) bool {
    return value == .string or value == .integer or value == .float;
}

fn canValueToInteger(value: Value) bool {
    _ = valueToInteger(value) catch return false;
    return true;
}

fn applyBinary(vm: *Vm, op: Token, left: Value, right: Value) !Value {
    return switch (op.tag) {
        .plus, .minus, .star, .slash, .floor_div, .percent => arithmetic(vm, op, left, right),
        .concat => concat(vm, op.line, left, right),
        .eq, .ne, .lt, .le, .gt, .ge => compare(vm, op, left, right),
        .amp, .pipe, .tilde, .shl, .shr => bitwise(vm, op.line, op.tag, left, right),
        else => error.UnsupportedFeature,
    };
}

fn arithmetic(vm: *Vm, op: Token, left: Value, right: Value) !Value {
    const tag = op.tag;
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
    const a = valueToNumber(left) catch {
        try setArithmeticRuntimeError(vm, op, left, right);
        return error.RuntimeError;
    };
    const b = valueToNumber(right) catch {
        try setArithmeticRuntimeError(vm, op, left, right);
        return error.RuntimeError;
    };
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

fn concat(vm: *Vm, line: usize, left: Value, right: Value) !Value {
    const l = valueToStringForConcat(vm.allocator, left) catch {
        vm.setRuntimeErrorAt(line, try concatErrorMessage(vm.allocator, left));
        return error.RuntimeError;
    };
    const r = valueToStringForConcat(vm.allocator, right) catch {
        vm.setRuntimeErrorAt(line, try concatErrorMessage(vm.allocator, right));
        return error.RuntimeError;
    };
    return .{ .string = try std.mem.concat(vm.allocator, u8, &.{ l, r }) };
}

fn valueToStringForConcat(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        else => error.RuntimeError,
    };
}

fn valueToStringForTostring(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    return switch (value) {
        .nil => "nil",
        .boolean => |b| if (b) "true" else "false",
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .string => |s| s,
        .table => "table",
        .function, .builtin, .wrapped_thread => "function",
        .thread => "thread",
    };
}

fn compare(vm: *Vm, op: Token, left: Value, right: Value) !Value {
    const result = switch (op.tag) {
        .eq => valuesEqual(left, right),
        .ne => !valuesEqual(left, right),
        .lt, .le, .gt, .ge => try orderedCompare(vm, op, left, right),
        else => unreachable,
    };
    return .{ .boolean = result };
}

fn valuesEqual(left: Value, right: Value) bool {
    if (left == .integer and right == .float) {
        return if (floatToInteger(right.float, .eq)) |i| left.integer == i else false;
    }
    if (left == .float and right == .integer) {
        return if (floatToInteger(left.float, .eq)) |i| i == right.integer else false;
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
        .thread => |v| v == right.thread,
        .wrapped_thread => |v| v == right.wrapped_thread,
    };
}

fn orderedCompare(vm: *Vm, op: Token, left: Value, right: Value) !bool {
    if (left == .integer and right == .integer) {
        return switch (op.tag) {
            .lt => left.integer < right.integer,
            .le => left.integer <= right.integer,
            .gt => left.integer > right.integer,
            .ge => left.integer >= right.integer,
            else => unreachable,
        };
    }
    if (left == .float and right == .float) {
        return switch (op.tag) {
            .lt => left.float < right.float,
            .le => left.float <= right.float,
            .gt => left.float > right.float,
            .ge => left.float >= right.float,
            else => unreachable,
        };
    }
    if (left == .integer and right == .float) {
        return switch (op.tag) {
            .lt => ltIntFloat(left.integer, right.float),
            .le => leIntFloat(left.integer, right.float),
            .gt => ltFloatInt(right.float, left.integer),
            .ge => leFloatInt(right.float, left.integer),
            else => unreachable,
        };
    }
    if (left == .float and right == .integer) {
        return switch (op.tag) {
            .lt => ltFloatInt(left.float, right.integer),
            .le => leFloatInt(left.float, right.integer),
            .gt => ltIntFloat(right.integer, left.float),
            .ge => leIntFloat(right.integer, left.float),
            else => unreachable,
        };
    }
    if (left == .string and right == .string) {
        const order = std.mem.order(u8, left.string, right.string);
        return switch (op.tag) {
            .lt => order == .lt,
            .le => order != .gt,
            .gt => order == .gt,
            .ge => order != .lt,
            else => unreachable,
        };
    }
    vm.setRuntimeErrorAt(op.line, try orderedComparisonErrorMessage(vm.allocator, left, right));
    return error.RuntimeError;
}

const FloatToIntegerMode = vm_table.FloatToIntegerMode;
const floatToInteger = vm_table.floatToInteger;

fn intFitsFloat(value: i64) bool {
    const max_exact_int_in_float: i64 = 9007199254740992;
    return value >= -max_exact_int_in_float and value <= max_exact_int_in_float;
}

fn ltIntFloat(integer: i64, float: f64) bool {
    if (intFitsFloat(integer)) return @as(f64, @floatFromInt(integer)) < float;
    if (floatToInteger(float, .ceil)) |ceil_float| return integer < ceil_float;
    return float > 0;
}

fn leIntFloat(integer: i64, float: f64) bool {
    if (intFitsFloat(integer)) return @as(f64, @floatFromInt(integer)) <= float;
    if (floatToInteger(float, .floor)) |floor_float| return integer <= floor_float;
    return float > 0;
}

fn ltFloatInt(float: f64, integer: i64) bool {
    if (intFitsFloat(integer)) return float < @as(f64, @floatFromInt(integer));
    if (floatToInteger(float, .floor)) |floor_float| return floor_float < integer;
    return float < 0;
}

fn leFloatInt(float: f64, integer: i64) bool {
    if (intFitsFloat(integer)) return float <= @as(f64, @floatFromInt(integer));
    if (floatToInteger(float, .ceil)) |ceil_float| return ceil_float <= integer;
    return float < 0;
}

fn orderedComparisonErrorMessage(allocator: std.mem.Allocator, left: Value, right: Value) ![]const u8 {
    const left_name = valueTypeName(left);
    const right_name = valueTypeName(right);
    if (std.meta.activeTag(left) == std.meta.activeTag(right)) {
        return try std.fmt.allocPrint(allocator, "attempt to compare two {s} values", .{left_name});
    }
    return try std.fmt.allocPrint(allocator, "attempt to compare {s} with {s}", .{ left_name, right_name });
}

fn setArithmeticRuntimeError(vm: *Vm, op: Token, left: Value, right: Value) !void {
    if (op.tag == .plus and (left == .string or right == .string)) {
        vm.setRuntimeMetamethodErrorAt(
            op.line,
            "add",
            try std.fmt.allocPrint(
                vm.allocator,
                "attempt to add a '{s}' with a '{s}'",
                .{ valueTypeName(left), valueTypeName(right) },
            ),
        );
        return;
    }
    const bad = if (left == .integer or left == .float) right else left;
    vm.setRuntimeErrorAt(
        op.line,
        try std.fmt.allocPrint(vm.allocator, "attempt to perform arithmetic on a {s} value", .{valueTypeName(bad)}),
    );
}

fn concatErrorMessage(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "attempt to concatenate a {s} value", .{valueTypeName(value)});
}

fn bitwiseErrorMessage(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    if (value == .float) return try std.fmt.allocPrint(allocator, "number has no integer representation", .{});
    return try std.fmt.allocPrint(allocator, "attempt to perform bitwise operation on a {s} value", .{valueTypeName(value)});
}

fn valueAccessErrorMessage(
    allocator: std.mem.Allocator,
    operation: []const u8,
    value: Value,
    name: ?[]const u8,
    scope: ValueScope,
) ![]const u8 {
    if (name) |n| {
        const scope_name = switch (scope) {
            .local => "local",
            .global => "global",
            .unknown => "",
        };
        if (scope != .unknown) {
            return try std.fmt.allocPrint(
                allocator,
                "attempt to {s} a {s} value ({s} '{s}')",
                .{ operation, valueTypeName(value), scope_name, n },
            );
        }
    }
    return try std.fmt.allocPrint(allocator, "attempt to {s} a {s} value", .{ operation, valueTypeName(value) });
}

fn valueTypeName(value: Value) []const u8 {
    return switch (value) {
        .nil => "nil",
        .boolean => "boolean",
        .integer, .float => "number",
        .string => "string",
        .table => "table",
        .function, .builtin, .wrapped_thread => "function",
        .thread => "thread",
    };
}

fn bitwise(vm: *Vm, line: usize, tag: TokenTag, left: Value, right: Value) !Value {
    const a = valueToInteger(left) catch {
        vm.setRuntimeErrorAt(line, try bitwiseErrorMessage(vm.allocator, left));
        return error.RuntimeError;
    };
    const b = valueToInteger(right) catch {
        vm.setRuntimeErrorAt(line, try bitwiseErrorMessage(vm.allocator, right));
        return error.RuntimeError;
    };
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
        .{ .source = "goto done\nlocal hidden\n::done::\n", .stdout = "" },
        .{ .source = "local preload_value = \"debug words are data\"\nlocal loader_count = 9\nprint(preload_value, loader_count)\n", .stdout = "debug words are data\t9\n" },
        .{ .source = "print((-9223372036854775808.0) & 1)\n", .stdout = "0\n" },
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
        .{ .source = "::l1::\ndo\n  ::l1::\nend\n", .diagnostic = "syntax-error:3:label 'l1' already defined on line 1" },
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

test "protected errors and coroutine smoke execute natively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippets = [_]struct { source: []const u8, stdout: []const u8 }{
        .{
            .source = "local ok, err = pcall(function() error(\"boom\", 0) end)\nprint(ok, err)\nlocal ok2, msg = xpcall(function() error(\"bad\", 0) end, function(e) return \"handled:\" .. e end)\nprint(ok2, msg)\n",
            .stdout = "false\tboom\nfalse\thandled:bad\n",
        },
        .{
            .source = "local token = {}\nlocal ok, err = pcall(function() error(token, 0) end)\nprint(ok, err == token, type(err))\nlocal handled = {}\nlocal ok2, got = xpcall(function() error(token, 0) end, function(e) print(\"handler\", e == token, type(e)) return handled end)\nprint(ok2, got == handled, type(got))\n",
            .stdout = "false\ttrue\ttable\nhandler\ttrue\ttable\nfalse\ttrue\ttable\n",
        },
        .{
            .source = "local first, second = {}, {}\nlocal count = 0\nlocal ok, got = xpcall(function() error(first, 0) end, function(e)\n  count = count + 1\n  print(\"handler-error\", count, e == first, e == second, type(e))\n  if count == 1 then error(second, 0) end\n  return e\nend)\nprint(ok, got == first, got == second, type(got), count)\n",
            .stdout = "handler-error\t1\ttrue\tfalse\ttable\nhandler-error\t2\tfalse\ttrue\ttable\nfalse\tfalse\ttrue\ttable\t2\n",
        },
        .{
            .source = "local function leveled() error(\"level boom\") end\nlocal ok, err = pcall(leveled)\nprint(ok, err)\nlocal ok0, err0 = pcall(function() error(\"level zero\", 0) end)\nprint(ok0, err0)\nlocal function g() error(\"caller level\", 2) end\nlocal function f() g() end\nlocal ok2, err2 = pcall(f)\nprint(ok2, err2)\n",
            .stdout = "false\tstdin:1: level boom\nfalse\tlevel zero\nfalse\tstdin:7: caller level\n",
        },
        .{
            .source = "local co = coroutine.create(function(a)\n  local b = coroutine.yield(a + 1)\n  return b + 2\nend)\nprint(coroutine.resume(co, 4))\nprint(coroutine.resume(co, 7))\nprint(coroutine.status(co))\n",
            .stdout = "true\t5\ntrue\t9\ndead\n",
        },
        .{
            .source = "local co = coroutine.create(function()\n  coroutine.yield(\"pause\")\n  return \"done\"\nend)\nprint(coroutine.resume(co))\nprint(coroutine.resume(co))\n",
            .stdout = "true\tpause\ntrue\tdone\n",
        },
        .{
            .source = "local got_a, got_b, got_c\nlocal function sink(a, b, c)\n  got_a, got_b, got_c = a, b, c\nend\nlocal co = coroutine.create(function()\n  sink(\"a\", coroutine.yield(\"pause\"), \"c\")\n  return got_a, got_b, got_c, \"done\"\nend)\nprint(coroutine.resume(co))\nprint(coroutine.resume(co, \"b\", \"extra\"))\nprint(coroutine.status(co))\n",
            .stdout = "true\tpause\ntrue\ta\tb\tc\tdone\ndead\n",
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

test "raw operations and metatable indexing execute natively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippets = [_]struct { source: []const u8, stdout: []const u8 }{
        .{
            .source = "local t = {}\nprint(rawget(t, \"x\"))\nrawset(t, \"x\", 4)\nprint(rawget(t, \"x\"), rawequal(rawget(t, \"x\"), 4), rawlen({1, 2, x = 3}))\n",
            .stdout = "nil\n4\ttrue\t2\n",
        },
        .{
            .source = "local t = setmetatable({}, { __index = function(_, k) return \"miss:\" .. k end })\nprint(t.answer)\n",
            .stdout = "miss:answer\n",
        },
        .{
            .source = "local t = setmetatable({}, { __metatable = \"locked\" })\nprint(getmetatable(t))\nlocal f = setmetatable({}, { __metatable = false })\nprint(getmetatable(f))\nlocal u = {}\nlocal mt = {}\nprint(setmetatable(u, mt) == u, getmetatable(u) == mt)\nprint(setmetatable(u, nil) == u, getmetatable(u))\n",
            .stdout = "locked\nfalse\ntrue\ttrue\ntrue\tnil\n",
        },
    };
    for (snippets) |snippet| {
        const result = try runLevel0(arena.allocator(), snippet.source);
        try std.testing.expectEqual(VmState.pass, result.state);
        try std.testing.expectEqualSlices(u8, snippet.stdout, result.stdout);
        try std.testing.expectEqualSlices(u8, "", result.stderr);
        _ = arena.reset(.retain_capacity);
    }
}

test "protected metatables reject replacement natively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippets = [_][]const u8{
        "local t = setmetatable({}, { __metatable = \"locked\" })\nsetmetatable(t, {})\n",
        "local t = setmetatable({}, { __metatable = false })\nsetmetatable(t, nil)\n",
    };
    for (snippets) |source| {
        const result = try runLevel0(arena.allocator(), source);
        try std.testing.expectEqual(VmState.runtime_error, result.state);
        try std.testing.expectEqual(@as(u8, 1), result.exit_code);
        try std.testing.expectEqualSlices(u8, "", result.stdout);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "cannot change a protected metatable") != null);
        _ = arena.reset(.retain_capacity);
    }
}

test "non-integral float table keys execute natively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippets = [_]struct { source: []const u8, stdout: []const u8 }{
        .{
            .source = "local t = {[1.5] = \"half\", [2.0] = \"two\"}\nt[3.25] = \"quarter\"\nrawset(t, 4.5, \"raw\")\nprint(t[1.5], t[2], rawget(t, 3.25), rawget(t, 4.5), rawget(t, 4))\nt[1.5] = nil\nprint(rawget(t, 1.5))\n",
            .stdout = "half\ttwo\tquarter\traw\tnil\nnil\n",
        },
        .{
            .source = "local t = {[1.5] = 10, [2.0] = 20, a = 1}\nlocal saw_float = false\nlocal sum = 0\nfor k, v in pairs(t) do\n  if k == 1.5 then saw_float = true end\n  sum = sum + v\nend\nprint(saw_float, sum)\n",
            .stdout = "true\t31\n",
        },
        .{
            .source = "local t = setmetatable({}, { __newindex = function(_, k, v) print(k, v) end })\nt[0/0] = \"nan-mm\"\nt[nil] = \"nil-mm\"\nprint(rawget({}, 0/0))\n",
            .stdout = "nan\tnan-mm\nnil\tnil-mm\nnil\n",
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

test "nan table writes retain lua-compatible diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippets = [_]struct { source: []const u8, diagnostic: []const u8 }{
        .{ .source = "local t = {}\nt[0/0] = 1\n", .diagnostic = "table index is NaN" },
        .{ .source = "rawset({}, 0/0, 1)\n", .diagnostic = "table index is NaN" },
        .{ .source = "local t = {[0/0] = 1}\n", .diagnostic = "table index is NaN" },
    };
    for (snippets) |snippet| {
        const result = try runLevel0(arena.allocator(), snippet.source);
        try std.testing.expectEqual(VmState.runtime_error, result.state);
        try std.testing.expectEqual(@as(u8, 1), result.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, snippet.diagnostic) != null);
        _ = arena.reset(.retain_capacity);
    }
}

test "generic for over pairs and ipairs iterator triples executes natively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippets = [_]struct { source: []const u8, stdout: []const u8 }{
        .{
            .source = "for i, v in ipairs({\"a\", \"b\"}) do print(i, v) end\n",
            .stdout = "1\ta\n2\tb\n",
        },
        .{
            .source = "local total = 0\nfor k, v in pairs({3, 4, 5}) do total = total + k + v end\nprint(total)\n",
            .stdout = "18\n",
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

test "ordered comparisons follow lua number string and invalid operand semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const success = try runLevel0(arena.allocator(),
        \\print(1 < 2, 2.0 <= 2, 3 > 2.5, 3 >= 3)
        \\print("2" < "10", "abc" <= "abc", "b" > "aa", "b" >= "b")
        \\
    );
    try std.testing.expectEqual(VmState.pass, success.state);
    try std.testing.expectEqualSlices(u8, "true\ttrue\ttrue\ttrue\nfalse\ttrue\ttrue\ttrue\n", success.stdout);
    _ = arena.reset(.retain_capacity);

    const invalid = try runLevel0(arena.allocator(), "print(\"2\" < 10)\n");
    try std.testing.expectEqual(VmState.runtime_error, invalid.state);
    try std.testing.expect(std.mem.indexOf(u8, invalid.stderr, "attempt to compare string with number") != null);
}

test "mixed integer float ordered comparisons preserve precision boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runLevel0(arena.allocator(),
        \\local a = 9007199254740993
        \\local b = 9007199254740992.0
        \\print(a < b, a <= b, a > b, a >= b)
        \\print(b < a, b <= a, b > a, b >= a)
        \\local c = 9223372036854775807
        \\local d = 9223372036854775807.0
        \\print(c < d, c <= d, c > d, c >= d)
        \\print(d < c, d <= c, d > c, d >= c)
        \\print(a == b, a ~= b, d == c, d ~= c)
        \\
    );
    try std.testing.expectEqual(VmState.pass, result.state);
    try std.testing.expectEqualSlices(
        u8,
        "false\tfalse\ttrue\ttrue\n" ++
            "true\ttrue\tfalse\tfalse\n" ++
            "true\ttrue\tfalse\tfalse\n" ++
            "false\tfalse\ttrue\ttrue\n" ++
            "false\ttrue\tfalse\ttrue\n",
        result.stdout,
    );
    try std.testing.expectEqualSlices(u8, "", result.stderr);
}

test "bitwise float coercion rejects nan and overflow without panicking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippets = [_][]const u8{
        "print(0/0 & 1)\n",
        "print(9223372036854775808.0 & 1)\n",
    };
    for (snippets) |source| {
        const result = try runLevel0(arena.allocator(), source);
        try std.testing.expectEqual(VmState.runtime_error, result.state);
        try std.testing.expectEqual(@as(u8, 1), result.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "number has no integer representation") != null);
        _ = arena.reset(.retain_capacity);
    }
}

test "vm level1 closures upvalues aliases and method calls execute natively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippets = [_]struct { source: []const u8, stdout: []const u8 }{
        .{ .source = "local function counter(start)\n  local value = start\n  return function()\n    value = value + 1\n    return value\n  end\nend\nlocal a = counter(10)\nlocal b = counter(5)\nprint(a(), a(), b())\n", .stdout = "11\t12\t6\n" },
        .{ .source = "local function outer(x)\n  local function inner() return x end\n  return inner\nend\nlocal f = outer(5)\nprint(f())\n", .stdout = "5\n" },
        .{ .source = "local function outer(x)\n  local function inner() return x end\n  local alias = inner\n  return alias\nend\nlocal f = outer(5)\nprint(f())\n", .stdout = "5\n" },
        .{ .source = "local function outer(x)\n  local function inner() return x end\n  local alias = inner\n  return (\n    alias\n  )\nend\nlocal f = outer(5)\nprint(f())\n", .stdout = "5\n" },
        .{ .source = "local function outer(x)\n  local function inner() return x end\n  local alias = (inner)\n  return alias\nend\nlocal f = outer(5)\nprint(f())\n", .stdout = "5\n" },
        .{ .source = "local function outer(x)\n  local function inner() return x end\n  local alias\n  alias = (inner)\n  return alias\nend\nlocal f = outer(5)\nprint(f())\n", .stdout = "5\n" },
        .{ .source = "local function outer(x)\n  local function inner() return x end\n  local first, second = nil, inner\n  return second\nend\nlocal f = outer(5)\nprint(f())\n", .stdout = "5\n" },
        .{ .source = "local function outer(x)\n  local function inner() return x end\n  local first, second\n  first, second = nil, inner\n  return second\nend\nlocal f = outer(5)\nprint(f())\n", .stdout = "5\n" },
        .{ .source = "local function outer(x)\n  local function inner() return x end\n  escaped = inner\nend\nouter(5)\nprint(escaped())\nescaped = nil\n", .stdout = "5\n" },
        .{ .source = "local function outer(x)\n  local function inner() return x end\n  local box = {}\n  box.fn = inner\n  return box.fn\nend\nlocal f = outer(5)\nprint(f())\n", .stdout = "5\n" },
        .{ .source = "local a = {}\nfor i = 1, 3 do\n  a[i] = function() return i end\nend\nprint(a[1](), a[2](), a[3]())\n", .stdout = "1\t2\t3\n" },
        .{ .source = "local a = {}\nfor i = 1, 3 do\n  local k = i * 10\n  a[i] = function() return i, k end\nend\nprint(a[1](), a[2](), a[3]())\n", .stdout = "1\t2\t3\t30\n" },
        .{ .source = "local a = {}\nfor k, v in ipairs({\"a\", \"b\", \"c\"}) do\n  a[k] = function() return k, v end\nend\nprint(a[1](), a[2](), a[3]())\n", .stdout = "1\t2\t3\tc\n" },
        .{ .source = "local box = { value = 7 }\nbox.get = function(self, extra) return self.value, extra end\nprint(box:get(3))\n", .stdout = "7\t3\n" },
        .{ .source = "local t = {}\nt.fn = function() return 1, 2 end\nprint(t.fn())\n", .stdout = "1\t2\n" },
        .{ .source = "local seen = {}\nlocal a = { b = { c = { marker = \"self\", f2 = function(self, k, n) seen[1], seen[2], seen[3] = self.marker, k, n end } } }\na.b.c:f2(\"k\", 12)\nprint(seen[1], seen[2], seen[3])\n", .stdout = "self\tk\t12\n" },
        .{ .source = "local t = {}\nt.fn = function(a, b) t[1], t[2] = a, b end\nt.fn(\"x\", \"y\")\nprint(t[1], t[2])\n", .stdout = "x\ty\n" },
        .{ .source = "local t = {}\nt[1] = function(a, b) t[2], t[3] = a, b end\nt[1](4, 5)\nprint(t[2], t[3])\n", .stdout = "4\t5\n" },
        .{ .source = "local function factory()\n  return { run = function(a, b) print(a, b) end }\nend\nfactory().run(\"chain\", 99)\n", .stdout = "chain\t99\n" },
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

test "vm level1 dynamic features remain explicitly unsupported fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippets = [_]struct { source: []const u8, reason: []const u8 }{
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
