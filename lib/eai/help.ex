defmodule Eai do
  @moduledoc false

  def help do
    IO.puts("""
    ═══════════════════════════════════════════════
       EAI 命令速查（全部公开 API）
    ═══════════════════════════════════════════════

    ## 对话入口
    Eai.Chat.talk(content: "msg", mod: :h|:f, model: :deepseek, prompt: :momoka, chat_session: "id", timeout: 30_000)
      返回 {:ok, reply} | {:error, reason}
    Eai.Chat.talk(content: "msg", mod: :f, chat_session: "y", pty_session_id: "x", model: :gpt4o, prompt: :coder)
      返回 {:ok, reply} | {:error, reason}

    ## 会话管理
    Eai.Chat.get_history()                    → 当前会话消息列表
    Eai.Chat.get_history("session")           → 指定会话消息列表
    Eai.Chat.list_chat_sessions()             → %{session_id => %{message_count, status}}
    Eai.Chat.interrupt!()                     → 中断当前会话
    Eai.Chat.interrupt!("session")            → 中断指定会话
    Eai.Chat.close_chat_session("session")    → 关闭会话
    Eai.Chat.export_history("path.gz")        → {:ok, path} | {:error, reason}
    Eai.Chat.export_history("path.gz", "session")
    Eai.Chat.replace_history("path.gz", "session", "converse|openai|anthropic")
      返回 {:ok, count} | {:error, reason}

    ## 模型查询
    Eai.Models.names()        #{inspect(Eai.Models.names())}
    Eai.Models.all()          → 全部条目详情列表
    Eai.Models.default()      → 默认模型条目
    Eai.Models.get(:gpt4o)    → 模型条目 | nil
    Eai.Models.get!(:gpt4o)   → 模型条目 (or raise)
    Eai.Models.vision_models()→ 视觉模型列表
    Eai.Models.default_vision()→ 第一个视觉模型
    Eai.Models.api_key(entry) → 读取环境变量中的 key
    Eai.Models.to_run_opts(entry) → 转为 run 用 opts map

    ## 提示词查询
    Eai.Prompts.names()       #{inspect(Eai.Prompts.names())}
    Eai.Prompts.list()        → 打印名称 + 描述
    Eai.Prompts.default()     → 默认提示词条目
    Eai.Prompts.get(:coder)   → 条目 | nil
    Eai.Prompts.get!(:coder)  → 条目 (or raise)
    Eai.Prompts.content(:momoka) → 提示词文本

    ## 数据清洗
    Eai.Utils.sanitize_value(term)       → 递归清洗非法 UTF-8
    Eai.Utils.sanitize_messages(messages) → 清洗消息列表

    ## 共享 Git 仓库
    Eai.Git.init_shared_repo()          → {:ok, :created|:already_exists} | {:error, ...}
    Eai.Git.get_shared_repo_path()      → 仓库路径

    ## 背景记录
    Eai.Record.start_link("dir", "session")  → GenServer 启动
    Eai.Record.stop()                        → 停止记录

    ## 工具函数（LLM 或用户直接调用）
    #{tool_table()}

    ## 高级：PTY 池直接操作
    alias Eai.Sandbox.PTYPool
    PTYPool.exec_async(session, cmd, task_id)   → {:ok, task_id} | {:error, :busy}
    PTYPool.list_sessions()                     → 所有 PTY 会话状态
    PTYPool.write_raw(session, raw_string)      → :ok
    PTYPool.interrupt_task(session)             → :ok
    PTYPool.force_reset(session)                → :ok
    PTYPool.clear_task(session, task_id)        → :ok

    ## 高级：LLM 直接调用
    Eai.LLM.Direct.run(messages, pty_session_id, opts)
      opts: %{model: :gpt4o, system_prompt: :coder, chat_session_id: "id", ...}

    ## 调试环境变量
    EAI_DEBUG_PTY=1           原始 PTY 输出
    EAI_DEBUG_LLM_REQUEST=1   打印完整 LLM 请求体
    EAI_WORK_DIR=/path        沙箱根目录
    OPENAI_API_KEY / DEEPSEEK_API_KEY / ANTHROPIC_API_KEY
    """)
  end

  defp tool_table do
    tools = [
      {"execute_script", "%{\"script\"=>\"...\"} -> task_id", "Eai.Tool.ExecuteScript"},
      {"get_task_result", "%{\"task_id\"=>\"...\"} -> 结果", "Eai.Tool.GetTaskResult"},
      {"write_to_session", "%{\"input\"=>\"y\\\\n\"} -> ok", "Eai.Tool.WriteToSession"},
      {"list_pty_sessions", "{} -> 会话列表", "Eai.Tool.ListPtySessions"},
      {"reset_session", "%{\"pty_session_id\"=>\"...\"} -> ok", "Eai.Tool.ResetSession"},
      {"force_complete_task", "%{\"task_id\"=>\"...\"} -> 输出", "Eai.Tool.ForceCompleteTask"},
      {"call_subagent", "%{\"message\"=>\"...\"} -> subagent_task_id", "Eai.Tool.CallSubagent"},
      {"get_subagent_result", "%{\"subagent_task_id\"=>\"...\"} -> 结果",
       "Eai.Tool.GetSubagentResult"},
      {"set_config",
       "%{\"key\"=>\"poll_cooldown_ms\", \"value\"=>3000} -> ok | list current values",
       "Eai.Tool.SetConfig"},
      {"get_local_time", "{} -> UTC ISO8601", "Eai.Tool.GetLocalTime"},
      {"read_media_file", "%{\"file_path\"=>\"...\", \"inject\"=>true, ...} -> 媒体/inject",
       "Eai.Tool.ReadMediaFile"},
      {"export_context", "%{\"file_path\"=>\"...\"} -> ok", "Eai.Tool.ExportContext"},
      {"replace_context", "%{\"file_path\"=>\"...\", \"format\"=>\"converse\"} -> ok",
       "Eai.Tool.ReplaceContext"},
      {"list_chat_sessions", "{} -> 会话列表", "Eai.Tool.ListChatSessions"}
    ]

    header =
      String.pad_trailing("工具", 22) <>
        String.pad_trailing("参数示例（调用 Eai.Tool.XXX.execute(map, pty, chat)）", 54) <> "模块"

    rows =
      Enum.map_join(tools, "\n", fn {name, params, mod} ->
        "  #{String.pad_trailing(name, 22)} #{String.pad_trailing(params, 52)} #{mod}"
      end)

    header <> "\n" <> rows
  end
end
