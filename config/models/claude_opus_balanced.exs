import Config

# Step 7 example: model config declaring Step 7 sampler/超参数 fields.
#
# This is a sibling of `claude_opus.exs` (which stays minimal). It exists
# to document the new model-config field surface and to provide a runnable
# example for users who want opinionated defaults at the model level
# (instead of passing `temperature: 0.3, top_p: 0.9, ...` to every
# `Eai.Chat.talk/1` call).
#
# All sampler fields are OPTIONAL. Any field omitted here means "no model-
# level default; consult the provider" — `nil` is propagated through
# `Eai.Models.to_run_opts/1` and ultimately omitted from the HTTP body.
#
# Precedence (per field, all 10 sampler fields):
#   `Eai.Chat.talk/1` explicit opt  >  this config file  >  nil/omit
#
# Fields supported by Anthropic (this provider): temperature, top_p, top_k,
# max_tokens, stop_sequences. The other 5 (min_p, repetition_penalty,
# frequency_penalty, presence_penalty, seed) are silently dropped by the
# Anthropic adapter. Declaring them here is harmless — see
# `docs/step7_changes.md` §D for the per-provider wire-format table.

config :eai, :model_claude_opus_balanced,
  name: :claude_opus_balanced,
  model: "claude-opus-4-6",
  url: "https://api.anthropic.com/v1/messages",
  provider: :anthropic,
  api_key_env: "ANTHROPIC_API_KEY",
  vision: true,
  receive_timeout: 120_000,

  # Step 7: 10 sampler/超参数 fields. Defaults are deliberately opinionated
  # for a "balanced" persona (low temperature, mid top_p, generous output
  # budget, no stop sequences). Override per-call via `Eai.Chat.talk/1`.
  temperature: 0.3,
  top_p: 0.9,
  top_k: 40,
  min_p: nil,
  max_tokens: 4096,
  repetition_penalty: nil,
  frequency_penalty: nil,
  presence_penalty: nil,
  stop_sequences: ["</answer>", "### END"],
  seed: nil,
  # Step 9: opt into the `output-128k-2025-02-19` beta header so Opus 4.6+
  # can use 131072 max_tokens. Same value as `claude_opus.exs` (both are
  # :claude_opus model strings, but `claude_opus_balanced` is a separate
  # `:model_claude_opus_balanced` entry in Application env, so it does
  # NOT inherit `anthropic_beta` from `claude_opus.exs` — we declare it
  # here for consistency). The `max_tokens: 4096` default above is well
  # below the 131072 cap, so the beta header is dormant in this config
  # unless the caller raises `max_tokens` above 8192.
  anthropic_beta: ["output-128k-2025-02-19"],
  # Step 10: Anthropic's `thinking` block `budget_tokens` field. nil =
  # Anthropic API rejects. No Eai-side fallback.
  reasoning_budget_tokens: 5000,
  # Step 10: `max_tokens` is pass-through. Anthropic Messages API requires
  # this field. Override per-call via `Eai.Chat.talk(max_tokens: N)`
  # still works (Step 7 plumbing).
  max_tokens: 8192
