import Config

# API Key 校验已下放到模型层（Eai.Models.api_key/1），
# 仅在实际发起请求时按模型的 api_key_env 字段按需读取，
# 这样可以同时支持多个供应商（DeepSeek、OpenAI、Anthropic、Ollama 等），
# 且未使用的供应商无需提前配置密钥。

# ── Sandbox 环境变量覆盖（可选）────────────────────────────────────
if work_dir = System.get_env("EAI_WORK_DIR") do
  config :eai, :sandbox, work_dir_root: work_dir
end

if debug_pty = System.get_env("EAI_DEBUG_PTY") do
  config :eai, :sandbox, debug_pty_output: debug_pty in ["1", "true", "yes"]
end

if priv = System.get_env("EAI_PRIV_SRC") do
  config :eai, :sandbox, priv_src: priv
else
  config :eai, :sandbox, priv_src: Path.expand("priv", File.cwd!())
end

# ── Mounts ────────────────────────────────────────────────────
# 每个 agent 创建时自动符号链接到其工作目录
default_mounts = Application.get_env(:eai, :sandbox, [])[:default_mounts] || []

mounts = if extra = System.get_env("EAI_MOUNTS") do
  default_mounts ++ String.split(extra, ":")
else
  default_mounts
end

config :eai, :sandbox, mounts: mounts

