import Config

config :eai, :model_claude_opus,
  name: :claude_opus,
  model: "claude-opus-4-6",
  url: "https://api.anthropic.com/v1/messages",
  provider: :anthropic,
  api_key_env: "ANTHROPIC_API_KEY",
  vision: true,
  receive_timeout: 120_000