defmodule Eai.Chat.Context do
  @moduledoc """
  Carries all LLM hyper-parameters through the interactive /
  function-mode call chain. Every field defaults to `nil`
  (absent → fall back to model config → omit from HTTP body).
  """

  @typedoc "Structure carrying a chat request and its options."
  @type t :: %__MODULE__{
          :message => String.t() | nil,
          :timeout => timeout() | nil,
          :model_opt => term() | nil,
          :prompt_opt => term() | nil,
          :chara_card_opt => term() | nil,
          :chat_session => String.t() | nil,
          :pty_session => String.t() | nil,
          :temperature_opt => number() | nil,
          :top_p_opt => number() | nil,
          :top_k_opt => pos_integer() | nil,
          :min_p_opt => number() | nil,
          :max_tokens_opt => pos_integer() | nil,
          :repetition_penalty_opt => number() | nil,
          :frequency_penalty_opt => number() | nil,
          :presence_penalty_opt => number() | nil,
          :stop_sequences_opt => [String.t()] | nil,
          :seed_opt => integer() | nil,
          :anthropic_beta_opt => term() | nil
        }

  defstruct [
    :message,
    :timeout,
    :model_opt,
    :prompt_opt,
    :chara_card_opt,
    :chat_session,
    :pty_session,
    :temperature_opt,
    :top_p_opt,
    :top_k_opt,
    :min_p_opt,
    :max_tokens_opt,
    :repetition_penalty_opt,
    :frequency_penalty_opt,
    :presence_penalty_opt,
    :stop_sequences_opt,
    :seed_opt,
    :anthropic_beta_opt
  ]
end
