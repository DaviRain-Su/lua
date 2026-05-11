# Zig-backed Lua 5.5 — 实施路线图与后续任务规划

> 基于 `docs/zig-lua-prd.md` 的 7 个里程碑，对照当前实现状态，拆分可执行任务。
> 更新日期：2026-05-11

---

## 1. 当前实现状态总览

### 1.1 代码规模

| 模块 | 文件 | 行数 | 实现程度 |
|------|------|------|----------|
| VM 核心 (`vm_level0.zig`) | 1 | 4568 | 🟢 Level 0–2 已实现（表达式、控制流、闭包、协程、元表、pcall） |
| CLI shell (`cli_shell.zig`) | 1 | 2518 | 🟢 7 个子命令全部可用 |
| Allocator (`allocator.zig`) | 1 | 432 | 🟢 Host/Arena/Bounded/Failing/Counting 全套 |
| Debug/C API gates (`debug_capi_gates.zig`) | 1 | 309 | 🟡 门控定义完成，实际 C API 桥接为 stub |
| Advanced hooks (`advanced_hooks.zig`) | 1 | 91 | 🟡 9 个语义边界定义，未接入 runtime |
| Object model (value/object/table/string/function/thread/userdata) | 7 | ~464 | 🟡 类型定义和构造器完成，Table 无实际 hash/array 存储 |
| AOT runner (`aot_runner.zig`) | 1 | 110 | 🟢 管道完成但实际走 VM 解释，无真正 Lua→Zig 代码生成 |
| Profile stubs | 2 | 79 | 🟢 构建验证用 |
| Runtime tests (`runtime_tests.zig`) | 1 | 146 | 🟢 allocator/object 构造器测试 |
| Validation tools | 8 | ~9127 | 🟢 baseline oracle、snippet corpus、CLI/VM 测试 |
| **总计** | ~27 | ~8900 | — |

### 1.2 PRD 里程碑完成度

| 里程碑 | 状态 | 说明 |
|--------|------|------|
| **M1: Baseline 与语义边界冻结** | ✅ 90% | testes/ 已分类、baseline oracle 已建；C 构建需修复链接问题 |
| **M2: Zig build skeleton** | ✅ 95% | build.zig 三 profile 完整、feature flags 完备 |
| **M3: Object model 与 allocator** | 🟡 60% | allocator 全套完成；object model 有类型骨架但 Table/String 无实际存储 |
| **M4: VM/interpreter track** | 🟢 75% | 树遍历 VM 覆盖 Level 0–3 语义，缺标准库 |
| **M5: AOT track** | 🟡 20% | 管道 + eligibility 检查存在，无真正代码生成 |
| **M6: Advanced semantics** | 🟡 40% | 协程/元表/pcall 在 VM 中实现；GC 为空、debug/C API 为 stub |
| **M7: Cross-target** | 🟡 50% | native + wasm 构建通过；SBF 仅有 metadata；无实际 WASM runtime 验证 |

### 1.3 已验证可运行的 Lua 特性

通过 `ziglua-vm` 实测确认：

- ✅ 基础类型：nil, boolean, integer, float, string, table, function
- ✅ 算术/比较/逻辑/位运算
- ✅ 字符串拼接
- ✅ 表（数组/记录/混合，float key）
- ✅ 控制流：if/elseif/else, while, repeat/until, numeric for, generic for (pairs/ipairs), goto/label, break
- ✅ 函数 & 多返回值 & tail call
- ✅ 闭包 + upvalue 捕获（含嵌套/循环闭包）
- ✅ vararg（`...`）
- ✅ `_ENV` 和全局变量
- ✅ 元表：`__index`, `__add`, `__tostring` 等
- ✅ 受保护调用：pcall, xpcall
- ✅ 协程：create/resume/yield/wrap/close/running/status
- ✅ rawget/rawset/rawequal/rawlen
- ✅ setmetatable/getmetatable
- ✅ select/type/tostring/print

### 1.4 未实现的特性

- ❌ 标准库模块：`math`, `string`, `table`, `io`, `os`, `package`, `utf8`, `coroutine`（作为库模块）
- ❌ GC（垃圾回收）
- ❌ 弱引用表 / finalizer
- ❌ Debug API
- ❌ C API ABI 兼容
- ❌ 二进制 chunk 加载 / `load` / `loadstring`
- ❌ `require` / module 系统
- ❌ 文件 I/O
- ❌ 真正的 AOT 代码生成（Lua → Zig source）
- ❌ 字节码 VM（当前为树遍历解释器）

---

## 2. 后续任务规划

按优先级分为 **Phase 1（基础加固）** → **Phase 2（标准库）** → **Phase 3（高级语义）** → **Phase 4（AOT & 性能）** → **Phase 5（跨平台 & 生产化）**。

---

### Phase 1: 基础加固（优先级最高，约 2-3 周）

#### T1.1 修复 C Lua 构建环境

**问题**: `make -s -j` 链接失败（`ld: unknown options: -E`），导致 stock Lua baseline 无法运行。

**任务**:
1. 诊断 makefile 中 LDFLAGS 在 macOS/clang 下的兼容性
2. 修复链接选项，使 `./lua` 可正常构建
3. 确保 `./all`（testes/all.lua）可运行作为 baseline oracle
4. 更新 `.gitignore` 和 makefile 注释

**验收**: `make -s -j && cd testes && ../lua -W all.lua` 成功退出。

---

#### T1.2 Table 实际存储实现

**问题**: 当前 `Table` struct 只有 `array_slots` 和 `hash_slots` 计数器，无实际键值对存储。VM 中的表操作全部在 Vm struct 内部用 `StringHashMap` 临时实现，与 object model 脱节。

**任务**:
1. 设计 `Table` 的 array part + hash part 双存储（参照 C Lua `ltable.c`）
2. 实现 `Table.get(key)`, `Table.set(key, value)`, `Table.len()`, `Table.next()`
3. 支持 integer key fast path（array part）
4. 支持 float key（`[1.0]` vs `[1]` 的语义）
5. 支持 metatable 查找链
6. 将 `vm_level0.zig` 中所有表操作迁移到 `Table` API
7. 添加 Table 单元测试

**验收**: 表操作（构造、索引、赋值、迭代、元表）全部通过 `Table` API，VM 不再直接操作 HashMap。

**预估**: ~800 行新增/修改

---

#### T1.3 String interning

**问题**: 当前 `String` struct 只有一个 slice 指针，无 interning。Lua 语义要求字符串相等用指针比较（interned）。

**任务**:
1. 设计 `StringTable`（hash table，存所有 interned string）
2. `String.intern(allocator, bytes)` — 相同内容返回同一指针
3. 支持 short string（interned）和 long string（不 interned）
4. 将 `Vm` 中所有字符串创建改为 interning
5. 添加 OOM 测试

**验收**: 相同内容的字符串 `ptr == ptr`，`tostring` 等操作使用 interned string。

**预估**: ~400 行

---

#### T1.4 Object model 统一

**问题**: value.zig 的 `Value` union 和 vm_level0.zig 内部的 `Value` union 是两套独立实现，未统一。

**任务**:
1. 将 `vm_level0.zig` 内部的 `Value` 替换为 `value.zig` 的 `Value`
2. 或反过来：将 `value.zig` 的 `Value` 作为 VM 内部表示的类型别名
3. 确保所有模块使用统一的 Value API
4. 添加 `Value.isTruthy()`, `Value.equalTo()`, `Value.lessThan()` 等方法

**验收**: 全项目只有一套 Value 定义，所有模块引用同一来源。

**预估**: ~300 行修改

---

#### T1.5 错误传播模型规范化

**问题**: 当前错误处理混合了 `setRuntimeError` + `VmResult.state` + Zig error union，不统一。

**任务**:
1. 定义 `LuaError` enum：`SyntaxError`, `RuntimeError`, `MemoryError`, `FileError`
2. 定义错误值传播：`error("msg")` 应传递 Lua error value（不只是 string）
3. pcall/xpcall 的 error value 保存和恢复
4. 错误消息格式统一（`source:line: message`）

**验收**: 所有错误路径使用统一模型，pcall 能正确捕获和传递任意 error value。

**预估**: ~200 行

---

### Phase 2: 标准库模块（约 3-4 周）

#### T2.1 标准库注册框架

**任务**:
1. 设计 `StdlibModule` interface：名称、注册函数、profile 门控
2. 实现 `registerStdlib(vm, profile)` — 根据 profile 注册允许的模块
3. 每个模块注册为全局 table（`math`, `string`, `table`, `io`, `os` 等）
4. `coroutine` 全局 table 复用现有协程 builtin

**验收**: `print(math.abs(-5))` 能正确输出 `5`。

**预估**: ~300 行框架

---

#### T2.2 math 库

**参照**: C Lua `lmathlib.c`（19049 行）

**任务**:
1. 实现 `math.abs`, `math.ceil`, `math.floor`, `math.max`, `math.min`
2. 实现 `math.sqrt`, `math.sin`, `math.cos`, `math.tan`, `math.exp`, `math.log`
3. 实现 `math.random`, `math.randomseed`
4. 常量：`math.pi`, `math.huge`, `math.maxinteger`, `math.mininteger`
5. 实现 `math.tointeger`, `math.type`

**验收**: `testes/math.lua` 子集通过。

**预估**: ~500 行

---

#### T2.3 string 库

**参照**: C Lua `lstrlib.c`（58316 行）

**任务**:
1. 基础：`string.len`, `string.sub`, `string.rep`, `string.reverse`, `string.upper`, `string.lower`
2. 查找：`string.find`, `string.match`, `string.gmatch`, `string.gsub`
3. 格式化：`string.format`（基础 %d, %s, %f, %x）
4. 转换：`string.byte`, `string.char`, `string.dump`
5. 模式匹配（Lua pattern，非正则）

**验收**: `testes/strings.lua` 子集通过。

**预估**: ~1200 行（pattern matching 是大头）

---

#### T2.4 table 库

**参照**: C Lua `ltablib.c`（13295 行）

**任务**:
1. `table.insert`, `table.remove`
2. `table.sort`（快速排序）
3. `table.concat`, `table.move`, `table.pack`, `table.unpack`

**验收**: `table.insert(t, 1); table.insert(t, 2); table.sort(t)` 正确。

**预估**: ~400 行

---

#### T2.5 io 库（native profile only）

**参照**: C Lua `liolib.c`（22402 行）

**任务**:
1. `io.open`, `io.close`, `io.read`, `io.write`, `io.lines`
2. 文件句柄对象
3. `io.stdout`, `io.stderr`, `io.stdin` 预定义
4. profile 门控：wasm/sbf 下 `io` 不可用

**验收**: 能读写文件，`testes/files.lua` 子集通过。

**预估**: ~600 行

---

#### T2.6 os 库（native profile only）

**参照**: C Lua `loslib.c`（11861 行）

**任务**:
1. `os.clock`, `os.time`, `os.date`, `os.difftime`
2. `os.getenv`, `os.execute`（subset）
3. profile 门控

**验收**: `os.date("*t")` 返回合理值。

**预估**: ~400 行

---

#### T2.7 package / require 系统

**参照**: C Lua `loadlib.c`（22899 行）

**任务**:
1. `require` 机制（搜索路径、缓存、loader）
2. `package.path`, `package.cpath`, `package.loaded`, `package.preload`
3. Lua source module 加载（不含 C 动态加载）
4. profile 门控：wasm/sbf 禁用 `package.loadlib`

**验收**: `local m = require "mymodule"` 能从文件系统加载并缓存。

**预估**: ~500 行

---

### Phase 3: 高级语义（约 3-4 周）

#### T3.1 垃圾回收 (GC)

**问题**: 当前所有对象只分配不回收，长期运行会 OOM。

**任务**:
1. 设计 GC 对象链表（allgc, finobj, weak 等）
2. 实现 mark-and-sweep 基础算法
3. 支持增量/分步 GC（step、pause 参数）
4. 弱引用表（`__mode = "k"/"v"/"kv"`）
5. finalizer（`__gc` 元方法）
6. 在 VM 的关键分配点触发 GC step
7. `collectgarbage` 函数

**验收**: 闭包测试和 GC 测试不泄漏，bounded allocator 下可观测 GC 回收。

**预估**: ~1500 行

---

#### T3.2 Debug 库（subset）

**参照**: C Lua `ldblib.c`（13217 行）和 `ltests.c`

**任务**:
1. `debug.getinfo` — 函数名、行号、源码位置
2. `debug.traceback` — 调用栈回溯
3. `debug.sethook` / `debug.gethook` — line/call/return hook
4. `debug.getlocal` / `debug.setlocal`
5. profile 门控：wasm 下仅 subset

**验收**: `debug.traceback()` 输出包含文件名和行号。

**预估**: ~800 行

---

#### T3.3 二进制 chunk 加载

**参照**: C Lua `lundump.c`（10916 行）, `ldump.c`（7900 行）

**任务**:
1. 实现 Lua binary chunk 格式解析器
2. 支持 `load()` 和 `loadstring()` 从字符串加载
3. 支持 `load()` 从 reader function 加载
4. `string.dump()` 生成二进制 chunk
5. 这将开启从 C Lua 生成的 bytecode 在 Zig runtime 中运行

**验收**: C Lua `string.dump(fn)` 的输出可被 Zig runtime `load()` 加载执行。

**预估**: ~1000 行

---

#### T3.4 Coroutine 完善

**问题**: 当前协程在 VM 内部以 continuation 传递实现，但不支持跨 yield 的 protected call。

**任务**:
1. 完善协程与 pcall 的交互（yield across pcall boundary）
2. `coroutine.isyieldable()` 在主线程中正确返回
3. 协程错误传播：resume 中的错误正确传递给调用者
4. `coroutine.wrap` 的错误处理（不返回 false+error，而是抛出）

**验收**: `testes/coroutine.lua` 全部通过。

**预估**: ~300 行

---

### Phase 4: AOT & 性能（约 4-6 周）

#### T4.1 字节码 VM

**问题**: 当前为树遍历解释器，每次执行都要解析 token 和 AST，性能差。

**任务**:
1. 定义 Zig 版 Lua 5.5 bytecode 指令集（复用 `lopcodes.h` 的 opcodes）
2. 实现 compiler：Lua AST → bytecode（或直接从 parser 生成 bytecode）
3. 实现 register-based bytecode VM（参照 `lvm.c`）
4. 支持 OP_MOVE, OP_LOADI, OP_LOADK, OP_ADD, OP_CALL, OP_RETURN 等核心指令
5. 逐步扩展到完整指令集

**验收**: 性能基准测试显示字节码 VM 比树遍历快 3-10 倍。

**预估**: ~3000 行

---

#### T4.2 AOT 代码生成（Level 0）

**问题**: 当前 AOT runner 只是走 VM fallback，没有真正生成 Zig 代码。

**任务**:
1. 设计 AOT eligibility analysis pass（静态可分析的 chunk）
2. 实现 Lua Level 0 → Zig source code lowering
   - 算术表达式 → Zig 表达式
   - 局部变量 → Zig 变量
   - if/while/for → Zig 控制流
3. 生成独立的 `.zig` 文件，可被 `zig build` 编译
4. fallback 规则：遇到 load/debug/复杂 metatable 等自动回退 VM
5. AOT 产物与 VM runtime 的链接模型

**验收**: `local x=1+2; print(x)` 能被 AOT 编译为独立 Zig 程序并输出 `3`。

**预估**: ~2000 行

---

#### T4.3 AOT 扩展（Level 1-2）

**任务**:
1. AOT 支持函数和闭包
2. AOT 支持 table 构造和基本操作
3. AOT 支持基本元表操作（`__index` / `__add` 等 fast path）
4. 生成优化报告（哪些可以 AOT，哪些需要 fallback）

**预估**: ~1500 行

---

### Phase 5: 跨平台 & 生产化（约 4-6 周）

#### T5.1 WASM runtime 实测

**任务**:
1. WASM host harness 完善（Node.js / Wasmtime / Wasmer）
2. 在 WASM 中运行 Level 0/1 测试
3. capability gate 实际验证（io/os/package 不可用）
4. bounded allocator 在 WASM 线性内存下的行为
5. 二进制大小优化（strip, -OReleaseSmall）

**验收**: `ziglua-wasm-constrained.wasm` 能在 Wasmtime 中执行 `print("hello")` 并输出。

**预估**: ~500 行

---

#### T5.2 SBF spike

**任务**:
1. 验证 Zig → BPF target 工具链可行性
2. 最小 Lua 子集在 SBF 上的运行可行性报告
3. compute budget / heap / stack / binary size 约束测量
4. 明确可行范围和不可行点

**验收**: 产出 SBF feasibility report 文档。

**预估**: ~300 行 + 报告文档

---

#### T5.3 性能基准套件

**任务**:
1. 建立 benchmark suite（fibonacci, binary-trees, n-body 等）
2. 对比 C Lua / Zig VM（树遍历）/ Zig VM（字节码）/ AOT 的性能
3. 内存使用对比
4. 建立 CI 可运行的 benchmark 脚本

**预估**: ~400 行测试 + 脚本

---

#### T5.4 Differential testing 自动化

**任务**:
1. 自动运行 `testes/` 全套在 C Lua 和 Zig VM 上
2. 输出 differential report（哪些测试 C Lua pass 而 Zig fail，反之亦然）
3. 集成到 CI
4. 对每个失败测试生成最小复现用例

**验收**: `testes/` 覆盖率报告自动生成，C Lua vs Zig VM 语义差异可见。

**预估**: ~600 行

---

#### T5.5 文档与 API 稳定化

**任务**:
1. Value/Object/Table/String/Closure API 文档
2. Allocator 使用指南
3. Profile 配置指南
4. AOT 使用指南
5. 嵌入式使用示例（从 Zig 宿主调用 Lua）

**预估**: 文档 ~2000 行

---

## 3. 优先级排序与依赖关系

```
Phase 1（基础加固）
  T1.1 C 构建修复 ──→ T1.2 Table 存储 ──→ T1.3 String interning
  T1.4 Object model 统一 ──→ T1.2
  T1.5 错误模型规范化 ──→ T1.2

Phase 2（标准库）── 依赖 Phase 1
  T2.1 标准库框架 ──→ T2.2 math ──→ T2.3 string ──→ T2.4 table
                   ──→ T2.5 io ──→ T2.6 os
                   ──→ T2.7 package

Phase 3（高级语义）── 依赖 Phase 2
  T3.1 GC ──→ T3.2 Debug
  T3.3 二进制 chunk
  T3.4 Coroutine 完善

Phase 4（AOT & 性能）── 依赖 Phase 3
  T4.1 字节码 VM ──→ T4.2 AOT Level 0 ──→ T4.3 AOT Level 1-2

Phase 5（跨平台）── 依赖 Phase 3，部分可与 Phase 4 并行
  T5.1 WASM 实测
  T5.2 SBF spike
  T5.3 性能基准 ── 依赖 T4.1
  T5.4 Differential testing ── 依赖 T1.1
  T5.5 文档 ── 任意时间
```

---

## 4. 建议执行顺序

**近期（接下来 2 周）**:
1. **T1.1** 修复 C Lua 构建 → 恢复 baseline oracle
2. **T1.2** Table 实际存储 → 这是所有后续标准库的基础
3. **T1.3** String interning → 正确的字符串语义
4. **T2.1 + T2.2** 标准库框架 + math 库 → 第一个可用的标准库

**中期（第 3-6 周）**:
5. T1.4 + T1.5 Object model 统一 + 错误模型
6. T2.3 string 库 + T2.4 table 库
7. T3.1 GC 基础
8. T3.3 二进制 chunk 加载

**远期（第 7-16 周）**:
9. T4.1 字节码 VM
10. T3.2 Debug 库
11. T4.2 + T4.3 AOT 代码生成
12. T5.1 + T5.2 WASM/SBF 跨平台
13. T5.3 + T5.4 性能和测试自动化
14. T5.5 文档

---

## 5. 风险和缓解

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| 树遍历 VM 重构到字节码 VM 工作量巨大 | Phase 4 延期 | 先用树遍历跑通语义，字节码 VM 作为独立模块并行开发 |
| Lua pattern matching 实现复杂 | string 库延期 | 先实现不依赖 pattern 的子集，pattern 后续补齐 |
| GC 与现有 Vm struct 的所有权冲突 | Phase 3 回归 | Phase 1 先统一 Object model，GC 设计时复用 Header 链表 |
| WASM/SBF 的 Zig target 不稳定 | Phase 5 受阻 | 先以 native profile 为主，WASM/SBF 作为 experimental |
| AOT 代码生成的 fallback 语义不兼容 | Phase 4 语义错误 | 严格 differential testing，任何 fallback 必须与 C Lua 行为一致 |

---

## 6. 成功指标

| 指标 | Phase 1 目标 | 最终目标 |
|------|-------------|----------|
| `testes/` 通过率 | 0%（C 构建修复后重新测量） | ≥ 80% |
| 标准库模块数 | 1（math） | 8（math/string/table/io/os/package/utf8/coroutine） |
| VM 性能 vs C Lua | ~0.1x（树遍历） | ≥ 0.5x（字节码 VM） |
| AOT 性能 vs C Lua | N/A | ≥ 2x（纯算术/控制流场景） |
| WASM 二进制大小 | 539 KB | < 300 KB（ReleaseSmall） |
| 已知语义差异 | 未测量 | 0 个未记录的差异 |
