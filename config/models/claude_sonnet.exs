import Config

config :eai, :model_claude_sonnet,
  name: :claude_sonnet,
  model: "claude-sonnet-4-6",
  url: "https://api.anthropic.com/v1/messages",
  provider: :anthropic,
  api_key_env: "ANTHROPIC_API_KEY",
  vision: true,
  receive_timeout: 60_000
