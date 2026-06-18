import Config

config :eai, :model_deepseek,
  name: :deepseek,
  model: "deepseek-v4-pro",
  url: "https://api.deepseek.com/chat/completions",
  provider: :openai_compat,
  api_key_env: "DEEPSEEK_API_KEY",
  reasoning_effort: "high",
  receive_timeout: 120_000
