import Config

config :eai, :model_gpt4o,
  name: :gpt4o,
  model: "gpt-4o",
  url: "https://api.openai.com/v1/chat/completions",
  provider: :openai_compat,
  api_key_env: "OPENAI_API_KEY",
  vision: true,
  receive_timeout: 60_000