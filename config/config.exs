import Config

# ── LLM ───────────────────────────────────────────────────────────────────────
config :eai, :llm,
  url:              "https://api.deepseek.com/chat/completions",
  model:            "deepseek-v4-pro",
  receive_timeout:  120_000,
  reasoning_effort: "high"

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
import_config "prompt.exs"

# ── 环境特定配置覆盖 ──────────────────────────────────────────────────────────
import_config "#{config_env()}.exs"
