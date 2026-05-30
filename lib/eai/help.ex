defmodule Eai do
  @moduledoc "EAI — Extreme minimal AI assistant with persistent terminal and recursive sub-agents."

  @user_guide """
  ╔══════════════════════════════════════════════════════════════╗
  ║              EAI 使用指南（User Guide）                     ║
  ╚══════════════════════════════════════════════════════════════╝

  1. 启动前配置
  ══════════════

  必需环境变量：
    export OPENAI_API_KEY=sk-你的密钥

  可选环境变量（均有内置默认值，按需覆盖）：

  ┌─────────────────────┬───────────────────────────────────┬─────────────────────────────┐
  │ 变量名              │ 作用                              │ 默认值                      │
  ├─────────────────────┼───────────────────────────────────┼─────────────────────────────┤
  │ EAI_LLM_URL         │ LLM API 地址                      │ DeepSeek chat completions   │
  │ EAI_LLM_MODEL       │ 模型名称                          │ deepseek-v4-pro             │
  │ EAI_LLM_TIMEOUT     │ 单次请求超时（毫秒）              │ 120000（2 分钟）            │
  │ EAI_WORK_DIR        │ PTY 会话工作目录根路径            │ /home/eai_agents            │
  │ EAI_DEBUG_PTY       │ 打印 PTY 原始输出（1/true/yes）   │ false                       │
  │ EAI_PRIV_SRC        │ priv/ 目录路径（脚本工具来源）    │ 项目根目录下的 priv/        │
  └─────────────────────┴───────────────────────────────────┴─────────────────────────────┘

  config/config.exs 中还有更底层的 sandbox 参数，通常无需修改：
    pty_cols / pty_rows      PTY 终端尺寸（默认 200×50）
    pty_init_sleep_ms        PTY 初始化等待（默认 200ms）
    pty_ready_sleep_ms       命令就绪等待（默认 300ms）
    script_tmp_prefix        临时脚本路径前缀（默认 /tmp/eai_）
    sentinel_left/right      输出边界哨兵字符串（不要改，除非调试）
    reasoning_effort         推理强度（"low" / "medium" / "high"，默认 high）

  系统 Prompt 在 config/prompt.exs 中，修改后重启即生效，无需重新编译。

  2. 启动
  ════════

    iex -S mix

  3. 对话方式
  ════════════

  ① 交互式多行模式（适合人类输入）
  ─────────────────────────────────
    iex> Eai.Chat.talk()

    进入后逐行输入，特殊指令：
      /s   发送消息（开始任务）
      /c   取消，清空当前输入

    设置任务超时（超时后助手会自行收尾并回复）：
      iex> Eai.Chat.talk(timeout: 30_000)   # 30 秒

    超时提示只是提醒，不会强行中断——助手会在看到提示后优雅地停下来。

  ② 单行消息模式（适合程序化调用）
  ───────────────────────────────────
    iex> Eai.Chat.talk(content: "帮我查一下时间")
    iex> Eai.Chat.talk(content: "列出当前目录文件", timeout: 15_000)

    返回值：{:ok, reply} 或 {:error, reason}

  ③ 查看完整对话历史（含工具调用）
  ────────────────────────────────────
    iex> Eai.Chat.get_history()

    返回消息列表，role 包括 user / assistant / tool。
    助手的工具调用在 "tool_calls" 字段，工具结果在 role: "tool" 的消息里。

  4. 中断控制
  ════════════

  强制中断当前正在运行的任务（仅对异步交互模式有效）：
    iex> Eai.Chat.interrupt!

  这会向助手注入一个中断信号，助手在下次轮询结果时会感知到并立即停下来回复。
  注意：同步单行模式会阻塞 iex，此时无法调用 interrupt!，直接 Ctrl+C 即可。

  5. 助手工具速览
  ════════════════

  助手可以使用以下工具（你无需手动调用，助手自行决策）：

  ┌──────────────────────────────┬────────────────────────────────────────────────────────┐
  │ 工具                         │ 说明                                                   │
  ├──────────────────────────────┼────────────────────────────────────────────────────────┤
  │ execute_script(script,       │ 在持久 PTY 会话中异步执行 bash 脚本，立即返回 task_id  │
  │   agent_id?)                 │                                                        │
  │ get_task_result(task_id)     │ 轮询脚本执行结果；返回 {status, time} 直到 complete    │
  │ write_to_session(input,      │ 向 PTY stdin 写入原始字节，用于交互式提示和控制字符    │
  │   agent_id?)                 │ 支持：\\n \\r \\t \\x03(Ctrl+C) \\x04(Ctrl+D) \\x1a      │
  │ list_sessions()              │ 列出所有活跃 PTY 会话及其当前任务                      │
  │ reset_session(agent_id)      │ 强制杀死并重置一个卡死的会话                           │
  │ call_subagent(message,       │ 派出独立子代理并行处理任务，立即返回 task_id           │
  │   agent_id?)                 │                                                        │
  │ get_subagent_result(task_id) │ 轮询子代理结果；返回 {status, time} 直到 complete      │
  │ get_local_time()             │ 返回当前 UTC 时间（ISO-8601）                          │
  └──────────────────────────────┴────────────────────────────────────────────────────────┘

  6. 内置脚本工具（助手在 PTY 里使用）
  ══════════════════════════════════════

  ① dispatch.py — 三元组知识图谱引擎
  ──────────────────────────────────────
  读取 <<{subject, predicate, object}. 格式的三元组，构建 DAG，支持四种查询：

    python priv/scripts/dispatch.py <文件或目录> matrix         # 可视化邻接矩阵
    python priv/scripts/dispatch.py <文件或目录> path A B       # A → B 最短路径
    python priv/scripts/dispatch.py <文件或目录> query A B 5    # 从 A 出发预算为 5 的有效跳
    python priv/scripts/dispatch.py <文件或目录> deps X         # X 依赖的所有节点

  支持递归扫描目录，兼容所有文本文件类型。

  ② read_record.exs — 对话日志阅读器
  ──────────────────────────────────────
  读取 Eai.Record 写入的 gzip 压缩对话日志：

    elixir priv/scripts/read_record.exs <文件> --limit 10        # 最近 10 条，人类可读
    elixir priv/scripts/read_record.exs <文件> --limit 5 --json  # 最近 5 条，JSON 格式

  日志文件通常在项目根目录下的 chat_records/ 中。

  7. 记忆体系
  ════════════

  EAI 使用两层知识网格持久化助手的长期记忆：

  ┌─────────────────────────────┬───────────────────────────────────────────────────────┐
  │ 文件                         │ 定位                                                 │
  ├─────────────────────────────┼───────────────────────────────────────────────────────┤
  │ TRANSITION.md（main 分支）  │ 全局长效知识：框架模块、用户档案、通用规则           │
  │ PROJECT_TRANSITION.md       │ 项目级临时知识：业务状态、特性标志、中间件配置       │
  │（feature 分支）             │ 随分支生灭                                           │
  └─────────────────────────────┴───────────────────────────────────────────────────────┘

  三元组格式：<<{subject, predicate, object}.
  写入原则：遇到值得记住的关系就追加一行，谓词自由描述，无需分类。

  长期记忆通过 Git bare 仓库（home/eai_agents/shared.git）持久化，
  助手会在适当时机自动 commit & push。

  8. 使用技巧
  ════════════

  ① 并行任务
  ─────────────
  让助手同时做多件事：
    "帮我同时做 A、B、C 三件事"
  助手会调用 call_subagent 派出多个子代理并行执行，最后汇总结果。
  子代理有独立 PTY 会话，互不干扰。

  ② 任务超时自收尾
  ─────────────────
  设置合理的 timeout，助手超时后会自动把已完成的工作整理好返回给你，
  而不是无限等待：
    iex> Eai.Chat.talk(content: "...", timeout: 60_000)

  ③ 会话卡死时
  ─────────────
  如果助手反馈某个任务一直没结果，你可以告诉它：
    "去 list_sessions 看看，reset 掉卡死的会话再重试"
  或直接 interrupt! 让它停下来重新规划。

  ④ 调试 PTY 输出
  ─────────────────
  遇到脚本行为异常时，开启原始输出日志：
    export EAI_DEBUG_PTY=1
  重启后 PTY 的每一个字节都会打印到 iex 控制台，方便排查哨兵匹配问题。

  ⑤ 切换模型
  ────────────
  临时换一个更便宜/更快的模型做测试：
    export EAI_LLM_MODEL=deepseek-chat
  重启即生效，不需要改代码。

  ⑥ 修改系统 Prompt
  ──────────────────
  编辑 config/prompt.exs，重启 iex 即生效，无需重新编译。
  可以调整助手的名字、风格、优先工具的顺序，或添加项目专属背景知识。

  ⑦ 对话记录归档
  ─────────────────
  需要回溯某次对话？启动一个 Record 进程：
    iex> Eai.Record.start_link("chat_records/session_date.gz")
  之后的所有消息会自动写入 gzip 压缩日志，用 read_record.exs 阅读。
  """

  @arch_doc """
  ╔══════════════════════════════════════════════════════════════╗
  ║              EAI 架构简介（Architecture）                   ║
  ╚══════════════════════════════════════════════════════════════╝

  监督树（one_for_one）
  ──────────────────────
    Phoenix.PubSub      消息广播（chat_updates 频道）
    Eai.Cache.Cache     Nebulex 本地缓存（任务结果 / 子代理结果 / 中断标记）
    Eai.Sandbox.PTYPool PTY 会话池（GenServer，管理多个 ExPTY 进程）
    Eai.Chat            主对话 GenServer（历史 / 任务 / 超时）

  请求链路
  ─────────
    talk() → Chat.handle_call → Task.async(Direct.run)
           → LLM API → handle_response
           → execute_tool（递归，直到无 tool_calls）
           → {:ok, reply, history}

  PTY 输出收集（双哨兵奇偶校验）
  ──────────────────────────────
    每条命令包裹在两对哨兵之间，ResultCollector 取第 2 次 START
    到第 2 次 END 之间的内容，过滤掉回显噪声。
    中间结果以 {status: "running", time: elapsed_ms} 压缩存储，
    不污染 LLM history。

  子代理机制
  ──────────
    call_subagent → Task.start → Eai.Chat.send（独立 Direct.run）
    → Cache.put（将结果存入 cache 键 subagent_result + task_id）
    主代理轮询 get_subagent_result，收到 complete 后继续。
  """

  def help(topic \\ :all)
  def help(:all),                                   do: (IO.puts(@user_guide);  :ok)
  def help(t) when t in [:architecture, "architecture"], do: (IO.puts(@arch_doc); :ok)
  def help(_), do: (IO.puts("未知主题。可用：Eai.help() / Eai.help(:architecture)"); :error)
end