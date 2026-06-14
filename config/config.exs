import Config

# ── Logger 元数据键声明 ───────────────────────────────────────────────────────
config :logger, :console,
  metadata: [
    :body,
    :buffer,
    :callback,
    :current_task,
    :dir,
    :duration_ms,
    :error,
    :event,
    :file,
    :hook,
    :hooks,
    :label,
    :link,
    :measurements,
    :metadata,
    :msg,
    :output_bytes,
    :priv_src,
    :pty,
    :pty_session_id,
    :reason,
    :size,
    :src,
    :state,
    :task_id
  ]

# ── 默认模型 ──────────────────────────────────────────────────────────────────
# 模型定义已拆分至 config/models/*.exs，每个文件以 :model_<name> 为 key 注册一项。
# 新增本地/自托管模型只需在 config/models/ 下新建一个 .exs 文件即可，无需修改此处。
# 修改默认模型：将下面的 atom 改为目标模型的 :name。
config :eai, :default_model, :deepseek

# ── 兼容层：从注册表中取第一个模型作为全局 :llm 配置 ────────────────────────
# （Eai.LLM.Direct 内部已通过 Eai.Models 查表，此段仅保留给可能直接读 :llm 的旧代码）
# 如需覆盖单个字段，直接在此处追加即可：
# config :eai, :llm, receive_timeout: 180_000

# ── Sandbox ───────────────────────────────────────────────────────────────────
config :eai, :sandbox,
  work_dir_root: "/home/eai_agents",
  script_tmp_prefix: "/tmp/eai_",
  # shared_repo_path:   "/custom/path/to/shared.git",
  pty_cols: 200,
  pty_rows: 50,
  pty_init_sleep_ms: 200,
  pty_ready_sleep_ms: 300,
  sentinel_left: "___EAI_START___",
  sentinel_right: "___EAI_END___",
  debug_pty_output: false

# 默认 2 秒
config :eai, :poll_cooldown_ms, 2_000

# ── Telemetry ─────────────────────────────────────────────────────────────────
config :eai, :telemetry_events, [
  {[:eai, :session, :spawn], "PTY session spawned"},
  {[:eai, :session, :reset], "PTY session force-reset"},
  {[:eai, :task, :start], "Task submitted"},
  {[:eai, :task, :chunk], "PTY chunk received"},
  {[:eai, :task, :complete], "Task complete"},
  {[:eai, :task, :timeout], "Task timed out"},
  {[:eai, :llm, :request, :start], "LLM request start"},
  {[:eai, :llm, :request, :stop], "LLM request stop"},
  {[:eai, :tool, :execute], "Tool executed"},
  {[:eai, :llm, :request, :error], "LLM request error"},
  {[:eai, :tool, :error], "Tool execution error"},
  {[:eai, :adapter, :anthropic, :to_request_body], "Anthropic adapter to_request_body"},
  {[:eai, :adapter, :anthropic, :from_response], "Anthropic adapter from_response"},
  {[:eai, :adapter, :anthropic, :from_messages], "Anthropic adapter from_messages"},
  {[:eai, :adapter, :converse, :to_request_body], "Converse adapter to_request_body"},
  {[:eai, :adapter, :converse, :from_response], "Converse adapter from_response"},
  {[:eai, :adapter, :converse, :from_messages], "Converse adapter from_messages"},
  {[:eai, :adapter, :openai, :to_request_body], "OpenAI adapter to_request_body"},
  {[:eai, :adapter, :openai, :from_response], "OpenAI adapter from_response"},
  {[:eai, :adapter, :openai, :from_messages], "OpenAI adapter from_messages"},
  {[:eai, :adapter, :mcp, :do_execute, :start], "MCP adapter do_execute start"},
  {[:eai, :adapter, :mcp, :do_execute, :stop], "MCP adapter do_execute stop"},
  {[:eai, :adapter, :mcp, :do_execute, :error], "MCP adapter do_execute error"}
]

# ── System Prompt ─────────────────────────────────────────────────────────────
# prompts loaded via config/prompts/

# ── 环境特定配置覆盖 ──────────────────────────────────────────────────────────
import_config "#{config_env()}.exs"
# ── API Endpoint ─────────────────────────────────────────────────────────────
# OpenAI-compatible HTTP API. External tools (chatgpt-on-wechat, bots, n8n)
# can use eai as a drop-in OpenAI replacement.
config :eai, :api,
  enabled: true,
  port: 4001,
  host: "0.0.0.0"

# ── MCP Servers ──────────────────────────────────────────────────────────────
# Each server gets its own file under config/mcp_servers/*.exs
# To enable a server, uncomment its file (or add a new one).
# Hot-reload at runtime: Eai.MCP.reload!()
