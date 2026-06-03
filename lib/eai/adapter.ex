defmodule Eai.Adapter do
  @moduledoc """
  Behaviour for LLM provider adapters.

  Each adapter converts between the internal Converse-based IR (Eai.Message)
  and a provider-specific wire format.
  """

  @doc """
  Convert internal messages to a provider-specific HTTP request.

  Returns: `%{url: String.t(), headers: [{String.t(), String.t()}], json_body: map()}`
  """
  @callback to_request_body(
              messages :: [Eai.Message.t()],
              model :: String.t(),
              system_prompt :: String.t(),
              tools :: [map()],
              opts :: keyword()
            ) :: %{url: String.t() | nil, headers: list(), json_body: map()}

  @doc """
  Parse a provider-specific API response body into an Eai.Message (assistant).
  """
  @callback from_response(resp_body :: map()) :: Eai.Message.t()

  @doc """
  Convert a raw provider-specific message list into internal IR.
  Used when importing conversation history (e.g. replace_context with format parameter).
  """
  @callback from_messages(raw_messages :: [map()]) :: [Eai.Message.t()]
end
