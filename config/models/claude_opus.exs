import Config

config :eai, :model_claude_opus,
  name: :claude_opus,
  model: "claude-opus-4-6",
  url: "https://api.anthropic.com/v1/messages",
  provider: :anthropic,
  api_key_env: "ANTHROPIC_API_KEY",
  vision: true,
  receive_timeout: 120_000,
  # Step 10: Anthropic's `thinking` block `budget_tokens` field. This is
  # the only Anthropic-specific resource constraint. nil = Anthropic API
  # rejects the request. No Eai-side fallback (we don't add code for
  # provider compatibility). Override per-model or per-call via
  # `Eai.Chat.talk(reasoning_budget_tokens: N)` is NOT supported in this
  # step; the field is model-config only.
  reasoning_budget_tokens: 5000,
  # Step 10: `max_tokens` is also pass-through (no `|| 8192` fallback in
  # the adapter). Anthropic's Messages API requires this field — nil
  # would be rejected. The model config is the right place to declare
  # the resource limit. Override per-call via
  # `Eai.Chat.talk(max_tokens: N)` is plumbed through Step 7.
  max_tokens: 8192,
  # Step 9: opt into the `output-128k-2025-02-19` beta header so Opus 4.6+
  # can use 131072 max_tokens (without this header, Anthropic API caps
  # the request at 8192 for Opus 4.6 / Opus 4.7). Real Anthropic API
  # honours this header; DeepSeek `/anthropic` compatible endpoint drops
  # it silently. Override per-call via `Eai.Chat.talk(anthropic_beta: [...])`.
  anthropic_beta: ["output-128k-2025-02-19"]
