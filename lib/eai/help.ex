defmodule Eai do
  @moduledoc "EAI — Extreme minimal AI assistant with persistent terminal and recursive sub-agents."

  @user_guide """
  ╔══════════════════════════════════════════════════════════════╗
  ║              EAI 使用指南（User Guide）                     ║
  ╚══════════════════════════════════════════════════════════════╝

  1. 启动前配置
  ══════════════

  必需环境变量：
    export OPENAI_API_KEY=sk-你的密钥          # OpenAI / DeepSeek 等

  可选环境变量（均有内置默认值）：
    ANTHROPIC_API_KEY       Claude 密钥（若使用）
    EAI_DEBUG_PTY=1          打印 PTY 原始输出
    EAI_PRIV_SRC             指定 priv/ 目录路径

  config/ 配置文件：
    config/models.exs      模型注册表
    config/prompts.exs      Prompt 库
    config/config.exs       沙箱参数（PTY 尺寸、冷却时间等）

  新增配置项（config/config.exs）：
    config :eai, :poll_cooldown_ms, 5_000   # get_task_result 最小调用间隔（毫秒）

  所有配置修改后重启 iex 即生效。

  2. 启动
  ════════

    iex -S mix

  3. 模型与 Prompt
  ═════════════════

    Eai.Models.names()        # => [:deepseek, :gpt4o, ...]
    Eai.Prompts.list()        # 查看可用 prompt

  对话中指定：
    Eai.Chat.talk(model: :gpt4o, prompt: :coder)
    Eai.Chat.talk(content: "你好", model: :claude_sonnet, timeout: 30_000)

  4. 对话方式
  ════════════

  交互式（多行）：
    Eai.Chat.talk()
    逐行输入，/s 发送，/c 取消。结果在后台执行，完成后自动打印。

  单行模式：
    Eai.Chat.talk(content: "执行 ls", timeout: 15_000)
    返回 {:ok, reply} 或 {:error, reason}

  查看历史：
    Eai.Chat.get_history()

  5. 中断与超时
  ════════════════

    Eai.Chat.interrupt!           # 强制中断当前异步任务
    超时设置：Eai.Chat.talk(timeout: 10_000)  # 超时后助手会优雅退出

  6. 助手工具速览
  ════════════════

    execute_script(script, agent_id?)      异步执行 bash，返回 task_id
    get_task_result(task_id)               轮询结果（受 poll_cooldown_ms 限制）
    write_to_session(input, agent_id?)     向 PTY 发送原始字节（支持 \\x03 中断）
    list_pty_sessions()                    列出所有活跃 PTY 会话
    reset_session(agent_id)                强制重置卡死的会话
    force_complete_task(task_id)           立即取出缓冲区结果，不终止进程
    call_subagent(message, agent_id?)      派出独立子代理，返回 subagent_task_id
    get_subagent_result(task_id)          轮询子代理结果（同样受冷却限制）
    get_local_time()                       UTC 时间
    read_media_file(file_path, ...)        读取图像/视频，可选视觉分析
    export_context(file_path)             导出对话历史为 gzip
    replace_context(file_path)            从 gzip 恢复对话历史

  7. 核心改进（v0.1.6+）
  ═══════════════════════════

  - 哨兵机制：使用 base64 编码输出哨兵，消除回显干扰，收集更可靠。
  - 轮询冷却：通过 poll_cooldown_ms 强制最小间隔，保护嵌入式设备。
  - 写入会话：write_to_session 支持转义序列，可直接发送 Ctrl+C 等控制字符。
  - 强制完成：force_complete_task 仅收割已有输出，不杀进程。
  - 调试脚本：设置 EAI_DEBUG_PTY=1 可查看所有 PTY 原始数据。

  8. 内置脚本（助手在 PTY 中使用）
  ══════════════════════════════════════

    priv/scripts/dispatch.py   三元组知识图谱查询
    priv/scripts/read_record.exs  读取压缩对话日志
    priv/scripts/media_reader.py  多媒体文件解析

  详细用法见架构文档或源代码。

  9. 使用技巧
  ═════════════

    - 并行任务：让助手同时做多件事，它会调用子代理。
    - 静默下载：要求“静默下载，完成后 echo done”，助手会自动添加 curl -s 等。
    - 长上下文管理：使用 export_context / replace_context 自动打包恢复。
  """

  @arch_doc """
  ╔══════════════════════════════════════════════════════════════╗
  ║              EAI 架构简介（Architecture）                   ║
  ╚══════════════════════════════════════════════════════════════╝

  监督树（one_for_one）
  ──────────────────────
    Phoenix.PubSub      消息广播
    Eai.Cache.Cache     Nebulex 本地缓存
    Eai.Sandbox.PTYPool PTY 会话池
    Eai.Chat            主对话 GenServer

  请求链路
  ─────────
    talk() → Chat.handle_call → Task.async(Direct.run)
           → LLM API → handle_response → execute_tool（递归）
           → {:ok, reply, history}

  PTY 输出收集（base64 哨兵 + 最后匹配）
  ────────────────────────────────────────
    命令执行时，哨兵通过 base64 管道输出，避免回显中包含明文哨兵。
    ResultCollector 取缓冲区中最后一次 START 与 END 之间的内容，
    简单可靠，无需奇偶校验。

  轮询冷却
  ─────────
    每次调用 get_task_result / get_subagent_result 前强制 sleep，
    时长由 config :poll_cooldown_ms 决定（默认 5000ms）。
    受限于 Task 子进程，不会阻塞 iex 主交互。

  子代理机制
  ──────────
    call_subagent → Task.start → Eai.Chat.send（独立会话）
    → Cache 存储结果，主代理通过 get_subagent_result 轮询。

  视觉模型路由
  ────────────
    read_media_file 可选 analyze_prompt，自动选择 vision 模型，
    支持 OpenAI / Anthropic 双协议。

  上下文管理
  ──────────
    export_context / replace_context 直接读写 gzip 压缩的对话历史，
    Eai.Record 可后台自动保存。

  调试
  ────
    设置环境变量 EAI_DEBUG_PTY=1 可输出完整 PTY 数据。
    脚本调试信息通过 maybe_debug_script 显示。
  """

  def help(topic \\ :all)
  def help(:all),                                   do: (IO.puts(@user_guide);  :ok)
  def help(t) when t in [:architecture, "architecture"], do: (IO.puts(@arch_doc); :ok)
  def help(_), do: (IO.puts("未知主题。可用：Eai.help() / Eai.help(:architecture)"); :error)
end