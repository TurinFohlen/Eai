import Config

# OPENAI_API_KEY 必须在运行时注入；其余 LLM 参数可选覆盖
if System.get_env("OPENAI_API_KEY") == nil do
  raise """
  环境变量 OPENAI_API_KEY 未设置。
  请在启动前执行：
    export OPENAI_API_KEY=sk-...
  或在 .env 文件中配置后 source 该文件。
  """
end

# 允许通过环境变量覆盖单个参数（可选）
if url = System.get_env("EAI_LLM_URL") do
  config :eai, :llm, url: url
end

if model = System.get_env("EAI_LLM_MODEL") do
  config :eai, :llm, model: model
end

if timeout = System.get_env("EAI_LLM_TIMEOUT") do
  config :eai, :llm, receive_timeout: String.to_integer(timeout)
end

if work_dir = System.get_env("EAI_WORK_DIR") do
  config :eai, :sandbox, work_dir_root: work_dir
end
