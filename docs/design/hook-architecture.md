# Eai Hook Framework — Architecture & Usage

## TL;DR

```elixir
# 写一个 hook 文件：
# config/hooks/10_my_guard.exs

defmodule MyGuard do
  use Eai.Hook, priority: 10

  def interest(:pre, tool_name, _payload),
    do: String.contains?(tool_name, "write_to_session")
  def interest(_, _, _), do: false

  def verdict(:pre, _tool, %{args: [cmd | _]}) do
    if String.contains?(cmd, "rm -rf /"),
      do: {:block, "blocked by MyGuard"},
      else: :ok
  end
  def verdict(:pre, _, _), do: :ok
  def verdict(:post, _, _, _), do: :ok
end

# 激活：
iex> Eai.Hub.reload!()
```

---

## 9 条锁死的设计决策

### 1. 拦截点集中在 `Eai.Hub.run/3`

所有 tool 调用从 `Eai.LLM.Direct` 里的 `mod.execute(args, ...)` 改成
`Eai.Hub.run(mod, :execute, [args, ...])`. 14 个 tool 模块本身**不动**。

### 2. 同进程函数调用

Hook 在 **caller 进程**内同步执行。没有 PubSub 广播，没有 GenServer round-trip。
优点：hook 可以同步 block（gateguard 模式），latency 低，错误边界清晰。

### 3. `Eai.Hub` 自我重编译

`Eai.Hub.Reloader.reload!/0` 用 `Code.compile_file/1` 重新编译 hook 文件。
旧的 hook module 被新版覆盖（BEAM 允许 `redefine_module`）。下一次 `Hub.run/3`
调用就会走新版。正在执行中的调用栈不受影响。

### 4. Application 启动自动 reload

`application.ex` 的 `start/2` 末尾用 `Task.start` + `500ms` 延迟在后台触发
首次 `Eai.Hub.reload!()`. 500ms 确保所有 supervisor children 都已经起来了。

### 5. priority 显式声明

`use Eai.Hook, priority: N` 决定执行顺序。数字越小越先跑。用户完全掌控编号空间。
Pipeline 内部用 `Enum.sort_by(..., & &1.priority)`.

### 6. timeout 交给用户

Pipeline 不加强制 timeout。需要 timeout 的 hook 自己用 `Task.await/2`:

```elixir
def verdict(:pre, _tool, payload) do
  task = Task.async(fn -> expensive_check(payload) end)
  case Task.await(task, 500) do
    :ok -> :ok
    _   -> {:block, "check timed out"}
  end
end
```

### 7. fail open + telemetry

Hook 抛错 → `Eai.Hub.Pipeline` 捕获，fire `[:eai, :hook, :error]` telemetry，
原调用**继续**（不 block）。一个坏 hook 不能杀死整个 tool call。

### 8. post-hook 是 pipeline

Post-hooks 按 priority 串行，**hook B 看到 hook A 改过的 result**（`Enum.reduce_while`）。
Block 一票否决，短路剩余 hooks。

### 9. 初始代码完整

`Eai.Hub` 初始版就包含完整 Pipeline 调用。`Pipeline.pre_hooks/3` 和 `post_hooks/4`
在 `:eai_hooks` 为空时直接 pass-through，不需要 "裸 apply fallback"。

---

## 文件结构

```
eai/
├── lib/eai/hooks/
│   ├── hook.ex          — Eai.Hook behaviour + __using__ 宏
│   ├── hub.ex           — Eai.Hub.run/3 + reload!/0 入口
│   ├── loader.ex        — 只读 introspection helper
│   ├── pipeline.ex      — pre_hooks/3 + post_hooks/4 + register/1
│   └── reloader.ex      — Code.compile_file + persistent_term 更新
├── config/hooks/
│   ├── 01_example.exs   — 示例：block 危险命令
│   └── 02_session_log.exs — 示例：纯观测 telemetry
```

---

## Telemetry 事件表

| Event | 阶段 | 触发时机 |
|-------|------|---------|
| `[:eai, :tool, :pre]` | Hub | tool 调用前（pre-hooks 之前） |
| `[:eai, :tool, :post]` | Hub | post-hooks 通过后 |
| `[:eai, :tool, :blocked]` | Hub | pre 或 post hook 返回 block |
| `[:eai, :hook, :error]` | Pipeline | hook 抛出异常（fail open 记录）|
| `[:eai, :hook, :session_log, :pre]` | Hook02 | SessionLogHook 每次 pre |
| `[:eai, :hook, :session_log, :post]` | Hook02 | SessionLogHook 每次 post |
| `[:eai, :chat, :session, :start]` | Chat | 新对话任务启动 |
| `[:eai, :chat, :session, :close]` | Chat | session 关闭 |
| `[:eai, :task, :interrupt, :set]` | Task | 中断标志写入 |
| `[:eai, :task, :timeout, :triggered]` | Task | 超时窗口触发 |
| `[:eai, :task, :timeout, :consumed]` | Task | 超时窗口被消耗 |
| `[:eai, :result_collector, :timeout, :consumed]` | ResultCollector | RC 侧超时消耗 |
| `[:eai, :result_collector, :interrupt, :set]` | ResultCollector | RC 侧中断设置 |

已有事件（保持不变）：
`[:eai, :session, :spawn]`, `[:eai, :session, :reset]`,
`[:eai, :task, :start]`, `[:eai, :task, :chunk]`, `[:eai, :task, :complete]`,
`[:eai, :task, :timeout]`, `[:eai, :llm, :request, :start]`, `[:eai, :llm, :request, :stop]`

---

## 使用指南

### 写一个 hook

```elixir
# config/hooks/10_my_hook.exs
defmodule MyHook do
  use Eai.Hook, priority: 10

  @impl true
  def interest(:pre, "Elixir.MyTool.execute", _payload), do: true
  def interest(_event, _tool, _payload), do: false

  @impl true
  def verdict(:pre, _tool, %{args: [args | _]}) do
    # args 是 tool 收到的 JSON 解析后的 map
    if Map.has_key?(args, "dangerous_key"),
      do: {:block, "MyHook: rejected"},
      else: :ok
  end
  def verdict(:pre, _tool, _payload), do: :ok

  @impl true
  def verdict(:post, _tool, _payload, result), do: {:modify, result <> " [audited]"}
end
```

### 加载 hooks

```bash
# 启动后自动加载（Application.start → 500ms → reload!）

# 手动重载（开发时）：
iex> Eai.Hub.reload!()

# 检查当前注册的 hooks：
iex> Eai.Hub.Loader.print_hooks()
iex> :persistent_term.get(:eai_hooks)

# 强制清空再 reload：
iex> :persistent_term.erase(:eai_hooks); Eai.Hub.reload!()

# CLI：
mix run -e "Eai.Hub.reload!()"
```

### 验证 hook 行为

```elixir
# 1. mix compile 无 warning
# 2. 启动 iex -S mix
# 3. 检查 hooks 加载：
iex> Eai.Hub.Loader.print_hooks()
# Registered hooks (2):
#   priority=10  Elixir.Eai.Hook.Example
#   priority=20  Elixir.Eai.Hook.SessionLog

# 4. 测试 pass-through：
iex> Eai.Hub.run(Eai.Hub, :reload!, [])
# {:ok, :ok}

# 5. 测试 block（需要 write_to_session tool 可用）：
iex> Eai.Chat.talk(content: "run: rm -rf /", mod: :function)
# LLM 会收到 "tool blocked by hook: ..." 错误返回

# 6. 观测 telemetry：
iex> :telemetry.attach("test", [:eai, :hook, :session_log, :pre],
...>   fn e, m, meta, _ -> IO.inspect({e, m, meta}) end, nil)
```

---

## PoC 范围 — 明示没做的

- **分布式 PubSub**：hooks 只在本节点同进程运行
- **完整 7 事件类型**：目前只有 `:pre` / `:post`（SessionStart/Stop/Chunk/Error 等按需扩展）
- **跨节点 hook 同步**：每个节点独立 `:persistent_term`
- **性能 benchmark**：hook pipeline 的 μs 级开销未测量
- **hook 热卸载**：`reload!` 重加载全部，没有单独 unload 一个 hook 的 API
- **UI 可视化**：看 registered hooks 只能 IEx

---

## 下一步建议

1. **扩展事件类型**：在 `interest/3` 加 `:session_start`, `:session_close`, `:llm_request` 等
2. **hook 依赖声明**：`@depends_on [AnotherHook]` 自动调整 priority 顺序
3. **分布式 gossip**：reload 广播到集群其他节点
4. **hook 测试 helper**：`Eai.Hook.Test.assert_blocked/2`, `assert_modified/2`
