import Config

# ── 模型注册表（统一在 models.exs 管理）──────────────────────────────────────
import_config "models.exs"

# ── 兼容层：从注册表中取第一个模型作为全局 :llm 配置 ────────────────────────
# （Eai.LLM.Direct 内部已通过 Eai.Models 查表，此段仅保留给可能直接读 :llm 的旧代码）
# 如需覆盖单个字段，直接在此处追加即可：
# config :eai, :llm, receive_timeout: 180_000

# ── Sandbox ───────────────────────────────────────────────────────────────────
config :eai, :sandbox,
  work_dir_root:      "/home/eai_agents",
  script_tmp_prefix:  "/tmp/eai_",
  # shared_repo_path:   "/custom/path/to/shared.git",
  pty_cols:           200,
  pty_rows:           50,
  pty_init_sleep_ms:  200,
  pty_ready_sleep_ms: 300,
  sentinel_left:      "___EAI_START___",
  sentinel_right:     "___EAI_END___",
  debug_pty_output:   false
config :eai, :poll_cooldown_ms, 2_000   # 默认 2 秒
# ── Telemetry ─────────────────────────────────────────────────────────────────
config :eai, :telemetry_events, [
  {[:eai, :session, :spawn],       "PTY session spawned"},
  {[:eai, :session, :reset],       "PTY session force-reset"},
  {[:eai, :task, :start],          "Task submitted"},
  {[:eai, :task, :chunk],          "PTY chunk received"},
  {[:eai, :task, :complete],       "Task complete"},
  {[:eai, :task, :timeout],        "Task timed out"},
  {[:eai, :llm, :request, :start], "LLM request start"},
  {[:eai, :llm, :request, :stop],  "LLM request stop"},
  {[:eai, :tool, :execute],        "Tool executed"},
  {[:eai, :llm, :request, :error], "LLM request error"},
  {[:eai, :tool, :error],          "Tool execution error"}
]

# ── System Prompt ─────────────────────────────────────────────────────────────
import_config "prompts.exs"

# ── 环境特定配置覆盖 ──────────────────────────────────────────────────────────
import_config "#{config_env()}.exs"
