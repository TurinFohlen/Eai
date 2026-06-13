import Config

# Ollama local — no API key required
config :eai, :model_llama3,
  name: :llama3,
  model: "llama3",
  url: "http://localhost:11434/v1/chat/completions",
  provider: :openai_compat,
  api_key_env: nil,
  receive_timeout: 120_000