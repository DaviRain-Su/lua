-- ZigLua VM Benchmark Suite
-- Run: cat benchmarks.lua | zig-out/bin/ziglua-vm
-- Compare: lua benchmarks.lua

print("=== ZigLua VM Benchmark Suite ===")
print()

-- 1. Empty loop
local t0 = os.clock()
for i = 1, 1000000 do end
local elapsed = os.clock() - t0
print(string.format("  %-30s %8.3f sec", "empty-loop-1M", elapsed))

-- 2. Arithmetic
t0 = os.clock()
local x = 0
for i = 1, 1000000 do x = x + 1 end
elapsed = os.clock() - t0
print(string.format("  %-30s %8.3f sec", "arithmetic-1M", elapsed))

-- 3. Table field access
t0 = os.clock()
local t = { x = 1, y = 2, z = 3 }
x = 0
for i = 1, 500000 do x = t.x + t.y + t.z end
elapsed = os.clock() - t0
print(string.format("  %-30s %8.3f sec", "table-field-500K", elapsed))

-- 4. Table creation
t0 = os.clock()
for i = 1, 100000 do local t2 = {} end
elapsed = os.clock() - t0
print(string.format("  %-30s %8.3f sec", "table-create-100K", elapsed))

-- 5. Function calls (recursive, no loops in functions)
t0 = os.clock()
local function id(val) return val end
x = 0
for i = 1, 500000 do x = id(i) end
elapsed = os.clock() - t0
print(string.format("  %-30s %8.3f sec", "func-call-500K", elapsed))

-- 6. Recursive fibonacci
t0 = os.clock()
local function fib(n)
    if n < 2 then return n end
    return fib(n-1) + fib(n-2)
end
fib(30)
elapsed = os.clock() - t0
print(string.format("  %-30s %8.3f sec", "fib(30)", elapsed))

-- 7. Math operations
t0 = os.clock()
x = 0
for i = 1, 500000 do x = math.sqrt(i) end
elapsed = os.clock() - t0
print(string.format("  %-30s %8.3f sec", "math-ops-500K", elapsed))

-- 8. Closures (no loops inside function bodies)
t0 = os.clock()
local function make_adder(val)
    return function(y) return val + y end
end
local add5 = make_adder(5)
x = 0
for i = 1, 500000 do x = add5(i) end
elapsed = os.clock() - t0
print(string.format("  %-30s %8.3f sec", "closures-500K", elapsed))

-- 9. Coroutine (no while, use recursion)
t0 = os.clock()
local function prod(n)
    if n <= 0 then return end
    coroutine.yield()
    prod(n-1)
end
local co = coroutine.create(prod)
for i = 1, 100000 do coroutine.resume(co, 100000) end
elapsed = os.clock() - t0
print(string.format("  %-30s %8.3f sec", "coroutine-100K", elapsed))

-- 10. String operations
t0 = os.clock()
local s = "hello world"
for i = 1, 200000 do s = string.upper(s); s = string.lower(s) end
elapsed = os.clock() - t0
print(string.format("  %-30s %8.3f sec", "string-ops-200K", elapsed))

-- 11. Debug traceback
t0 = os.clock()
for i = 1, 10000 do debug.traceback() end
elapsed = os.clock() - t0
print(string.format("  %-30s %8.3f sec", "traceback-10K", elapsed))

print()
print("=== Done ===")
