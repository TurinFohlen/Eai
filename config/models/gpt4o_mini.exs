import Config

config :eai, :model_gpt4o_mini,
  name: :gpt4o_mini,
  model: "gpt-4o-mini",
  url: "https://api.openai.com/v1/chat/completions",
  provider: :openai_compat,
  api_key_env: "OPENAI_API_KEY",
  vision: true,
  receive_timeout: 30_000