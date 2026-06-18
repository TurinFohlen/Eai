import Config

config :eai, :model_claude_sonnet,
  name: :claude_sonnet,
  model: "claude-sonnet-4-6",
  url: "https://api.anthropic.com/v1/messages",
  provider: :anthropic,
  api_key_env: "ANTHROPIC_API_KEY",
  vision: true,
  receive_timeout: 60_000,
  # Step 10: Anthropic's `thinking` block `budget_tokens` field. nil =
  # Anthropic API rejects. No Eai-side fallback.
  reasoning_budget_tokens: 5000,
  # Step 10: `max_tokens` is also pass-through. Anthropic Messages API
  # requires this field. Default 8192 to match the prior hardcoded
  # fallback (now removed from the adapter).
  max_tokens: 8192,
  # Step 9: opt into the `output-128k-2025-02-19` beta header so Sonnet 4.6
  # / Fable 5 can use 65536 max_tokens (without this header, Anthropic API
  # caps the request at 8192). Real Anthropic API honours this header;
  # DeepSeek `/anthropic` compatible endpoint drops it silently. Override
  # per-call via `Eai.Chat.talk(anthropic_beta: [...])`.
  anthropic_beta: ["output-128k-2025-02-19"]
