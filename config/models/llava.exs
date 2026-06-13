import Config

# Ollama local — no API key required
config :eai, :model_llava,
  name: :llava,
  model: "llava",
  url: "http://localhost:11434/v1/chat/completions",
  provider: :openai_compat,
  api_key_env: nil,
  vision: true,
  receive_timeout: 120_000